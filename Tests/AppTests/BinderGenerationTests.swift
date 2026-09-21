import CeolKitParser
import CeolKitSVGRenderer
import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// Drives `BinderService` against a seeded catalogue: every tune page in order,
/// with a title page ahead of each titled section and standing on its own wherever
/// a section holds no tunes (#46), and every page numbered by its position in the
/// binder rather than in its tune.
final class BinderGenerationTests: XCTestCase {

    var app: Application!
    var workspace: URL!
    var service: BinderService!
    var branch: Branch!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binder-generation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        service = BinderService(musicWorkspacePath: workspace.path)

        branch = Branch(name: "2026")
        try await branch.save(on: app.db)
        for slug in ["march", "reel", "jig"] {
            try await seedTune(slug, branch: branch)
        }
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: workspace)
    }

    func testTitledSectionsGetTitlePages() async throws {
        let spec = BinderSpec(name: "Sections", branch: "2026", sections: [
            // Untitled: no title page, just the tune.
            BinderSection(title: nil, entries: [entry("march")]),
            // Titled: a title page, then both tunes.
            BinderSection(title: "Parade Set", entries: [entry("reel"), entry("jig")]),
            // Titled with nothing that resolves: no title standing over nothing.
            BinderSection(title: "Gone", entries: [entry("no_such_tune")]),
            // A blank title is no title, with or without tunes under it.
            BinderSection(title: "  ", entries: [entry("march")]),
            BinderSection(title: "  ", entries: []),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["march", "title: Parade Set", "reel", "jig", "march"])
    }

    /// The front matter the issue opens with: three title pages in a row, the
    /// first of them two lines and belonging to the binder rather than to any
    /// section, and none of them owning the tune that follows (#46).
    func testTitleOnlySectionsStandAsPagesOfTheirOwn() async throws {
        let spec = BinderSpec(name: "2027 Band Binder", branch: "2026", sections: [
            BinderSection(title: ["SVPB Music", "2027"], entries: []),
            BinderSection(title: "G4 Tunes", entries: []),
            BinderSection(title: "G4 Medley", entries: [entry("march")]),
            BinderSection(title: nil, entries: [entry("reel")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), [
            "title: SVPB Music / 2027",
            "title: G4 Tunes",
            "title: G4 Medley",
            "march",
            "reel",
        ])
        // Front matter is paper too: the medley opens on 4, not on 1.
        XCTAssertEqual(printedPageNumbers(pages), [4, 5])
    }

    /// A two-line title page is one page carrying two lines, not two pages and
    /// not one line with the break swallowed.
    func testMultiLineTitleIsOnePageOfStackedLines() async throws {
        let spec = BinderSpec(name: "Cover", branch: "2026", sections: [
            BinderSection(title: ["SVPB Music", "2027"], entries: []),
            BinderSection(title: nil, entries: [entry("march")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(pages.count, 2)
        guard case .titlePage(let title, let svg) = pages[0] else {
            return XCTFail("First page is not a title page")
        }
        XCTAssertEqual(title.pageLines, ["SVPB Music", "2027"])
        XCTAssertEqual(svg.components(separatedBy: "</svg>").count - 1, 1, "More than one page")
        let baselines = svg.matches(of: /<g transform="translate\([-0-9.]+ ([-0-9.]+)\)">/)
            .compactMap { Double($0.1) }
        XCTAssertEqual(baselines.count, 2, "The two lines did not stack")
        XCTAssertLessThan(baselines[0], baselines[1], "The second line is not below the first")
    }

    /// A section that is neither a title nor any tunes is nothing at all, and
    /// must not cost a blank page.
    func testEmptyUntitledSectionProducesNothing() async throws {
        let spec = BinderSpec(name: "Empty", branch: "2026", sections: [
            BinderSection(title: nil, entries: []),
            BinderSection(title: "Parade Set", entries: [entry("march")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["title: Parade Set", "march"])
    }

    /// A binder stored in the flat shape assembles exactly as it did before.
    func testFlatSpecHasNoTitlePages() async throws {
        let json = #"{"name":"Old","branch":"2026","entries":[{"tune_slug":"jig","parts":["Melody"]},{"tune_slug":"reel","parts":["Melody"]}]}"#
        let spec = try JSONDecoder().decode(BinderSpec.self, from: Data(json.utf8))

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["jig", "reel"])
    }

    // MARK: - Page numbering (#19)

    /// The headline of the whole binder feature: a tune prints where it sits in *this*
    /// binder, not where it sits in its own file. Every seeded tune is one page, so the
    /// third entry has to print 3 — it printed 1 before the binder re-engraved it.
    func testFootersNumberFromTheBinderNotTheTune() async throws {
        let spec = BinderSpec(name: "Numbers", branch: "2026", sections: [
            BinderSection(title: nil, entries: [entry("march"), entry("reel"), entry("jig")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(printedPageNumbers(pages), [1, 2, 3])
    }

    /// A title page is a sheet of paper, so the tune behind it is numbered as though
    /// it were one — the number has to match what a reader counts, not what a renderer
    /// happens to have drawn.
    func testTitlePagesAreCountedEvenThoughTheyPrintNoNumber() async throws {
        let spec = BinderSpec(name: "Divided", branch: "2026", sections: [
            BinderSection(title: "Parade Set", entries: [entry("march")]),
            BinderSection(title: "Slow Airs", entries: [entry("reel")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages),
                       ["title: Parade Set", "march", "title: Slow Airs", "reel"])
        // Pages 1 and 3 are the title pages; the tunes behind them are 2 and 4.
        XCTAssertEqual(printedPageNumbers(pages), [2, 4])
    }

    /// Numbering advances by the pages a tune actually takes, not by one per entry.
    func testAMultiPageTuneAdvancesTheNumberingByItsLength() async throws {
        let found = try await Branch.find("2026", on: app.db)
        let branch = try XCTUnwrap(found)
        try await seedTune("long", branch: branch, pages: 2)

        let spec = BinderSpec(name: "Long", branch: "2026", sections: [
            BinderSection(title: nil, entries: [entry("long"), entry("jig")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["long", "long", "jig"])
        XCTAssertEqual(printedPageNumbers(pages), [1, 2, 3])
    }

    /// A tune the catalogue has no ABC source for still reaches the binder, from the
    /// pages the build made of it — unnumbered, but present.
    func testATuneWithNoABCSourceFallsBackToTheBuildsPages() async throws {
        let found = try await Tune.query(on: app.db).filter(\.$slug == "reel").first()
        let tune = try XCTUnwrap(found)
        tune.abcPath = nil
        try await tune.save(on: app.db)

        let spec = BinderSpec(name: "Fallback", branch: "2026", sections: [
            BinderSection(title: nil, entries: [entry("march"), entry("reel")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["march", "prebuilt: reel"])
        // The fallback page is still a page: it keeps its slot in the count.
        XCTAssertEqual(pages.count, 2)
    }

    /// The whole path, through SVGPDFKit to a file the download route can serve.
    func testGeneratesPDFWithDividers() async throws {
        let spec = BinderSpec(name: "Sections", branch: "2026", sections: [
            BinderSection(title: "Parade Set", entries: [entry("reel")]),
        ])
        let request = BinderRequest(definition: spec)
        try await request.save(on: app.db)

        await service.generateBinder(requestID: try request.requireID(), db: app.db, logger: app.logger)

        let reloaded = try await BinderRequest.find(request.id, on: app.db)
        let path = try XCTUnwrap(reloaded?.pdfPath, "Binder was not generated")
        XCTAssertTrue(try Data(contentsOf: URL(fileURLWithPath: path)).starts(with: Data("%PDF".utf8)))
    }

    /// Dividers alone are not a binder.
    func testBinderWithOnlyDividersIsNotProduced() async throws {
        let spec = BinderSpec(name: "Empty", branch: "2026", sections: [
            BinderSection(title: "Gone", entries: [entry("no_such_tune")]),
        ])
        let request = BinderRequest(definition: spec)
        try await request.save(on: app.db)

        await service.generateBinder(requestID: try request.requireID(), db: app.db, logger: app.logger)

        let reloaded = try await BinderRequest.find(request.id, on: app.db)
        XCTAssertNil(reloaded?.pdfPath)
    }

    // MARK: - One tune, once (#24)

    /// A multi-voice tune goes in once however many of its parts the entry names.
    ///
    /// The builder used to select every part by default and append the same score per
    /// part, so a member who touched nothing got each harmonised tune two or three times
    /// over. The page no longer offers the choice, but shared URLs and stored requests
    /// written while it did still name every voice, and they have to assemble correctly.
    func testEntryNamingEveryPartYieldsTheTuneOnce() async throws {
        try await seedTune("air", branch: branch, extraParts: ["Harmony 1", "Harmony 2"])

        let spec = BinderSpec(name: "Voices", branch: "2026", sections: [
            BinderSection(title: nil, entries: [
                BinderEntry(tuneSlug: "air", parts: ["Melody", "Harmony 1", "Harmony 2"]),
            ]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["air"])
    }

    /// An entry that names one part gets that tune — whole, since that is all there is
    /// to give — and still only once.
    func testEntryNamingOnePartYieldsTheTuneOnce() async throws {
        try await seedTune("air", branch: branch, extraParts: ["Harmony 1"])

        let spec = BinderSpec(name: "One Voice", branch: "2026", sections: [
            BinderSection(title: nil, entries: [BinderEntry(tuneSlug: "air", parts: ["Harmony 1"])]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["air"])
    }

    /// Page numbers count sheets of paper, so removing the duplicates has to move the
    /// numbering with them: three multi-voice tunes are pages 1, 2, 3 — not 1, 4, 7.
    func testDeduplicatedEntriesRenumberTheBinder() async throws {
        for slug in ["first", "second", "third"] {
            try await seedTune(slug, branch: branch, extraParts: ["Harmony 1", "Harmony 2"])
        }
        let all = ["Melody", "Harmony 1", "Harmony 2"]

        let spec = BinderSpec(name: "Numbered", branch: "2026", sections: [
            BinderSection(title: nil, entries: ["first", "second", "third"].map {
                BinderEntry(tuneSlug: $0, parts: all)
            }),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["first", "second", "third"])
        XCTAssertEqual(printedPageNumbers(pages), [1, 2, 3])
    }

    /// A named part the build never converted does not cost the tune its place: the
    /// entry falls through to a part that does have pages.
    func testEntryFallsThroughToAPartWithPages() async throws {
        try await seedTune("air", branch: branch)
        let tune = try await Tune.query(on: app.db).filter(\.$slug == "air").first()!
        try await Part(tune: tune, name: "Bass", svgPaths: nil).save(on: app.db)

        let spec = BinderSpec(name: "Gap", branch: "2026", sections: [
            BinderSection(title: nil, entries: [BinderEntry(tuneSlug: "air", parts: ["Bass", "Melody"])]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["air"])
    }

    // MARK: - Helpers

    private func entry(_ slug: String) -> BinderEntry {
        BinderEntry(tuneSlug: slug, parts: ["Melody"])
    }

    /// Tune pages by slug, title pages by their text, so a test reads as the
    /// binder's contents.
    private func describe(_ pages: [BinderService.Page]) -> [String] {
        pages.map { page in
            switch page {
            case .tune(let slug, _):
                slug
            case .prebuilt(let slug, _):
                "prebuilt: \(slug)"
            case .titlePage(let title, let svg):
                svg.contains("title-page") ? "title: \(title.display)" : "malformed title: \(title.display)"
            }
        }
    }

    /// What each engraved tune page prints as its page number.
    ///
    /// Read from the `ceolkit-meta` comment CeolKit writes onto every page, which carries
    /// "the number the page *prints* — the same value `$P` engraves into the footer".
    /// The footer itself is glyph outlines by the time it reaches an SVG, so this comment
    /// is the only thing in the document that still says the number in digits.
    private func printedPageNumbers(_ pages: [BinderService.Page]) -> [Int] {
        pages.compactMap { page -> Int? in
            guard case .tune(_, let svg) = page else { return nil }
            guard let match = svg.firstMatch(of: /ceolkit-meta: \{"page": (\d+)/) else { return nil }
            return Int(match.1)
        }
    }

    /// Writes a tune's ABC where the build would, engraves it, and records both in the
    /// catalogue — the shape `BinderService` re-engraves from and falls back to.
    private func seedTune(_ slug: String, branch: Branch, pages: Int = 1,
                          extraParts: [String] = []) async throws {
        let body = "ABcd efga | gfed cBAG | ABcd efga | g2 f2 e2 d2 |]"
        let abc = """
        %abc-2.2
        %%footer "$P"
        X:1
        T:\(slug)
        M:4/4
        L:1/8
        K:D
        \(Array(repeating: body, count: pages).joined(separator: "\n%%newpage\n"))
        """
        let abcURL = workspace.appendingPathComponent("\(slug).abc")
        try abc.write(to: abcURL, atomically: true, encoding: .utf8)

        let parsed = CeolKitParser().parse(abc, options: .default)
        let svgs = try SVGRenderer(config: .init(pageSize: .letter)).render(parsed.score)
        XCTAssertEqual(svgs.count, pages, "Seed tune '\(slug)' should be \(pages) page(s)")

        var svgPaths: [String] = []
        for (index, svg) in svgs.enumerated() {
            let url = workspace.appendingPathComponent(String(format: "%@%03d.svg", slug, index))
            try svg.write(to: url, atomically: true, encoding: .utf8)
            svgPaths.append(url.path)
        }

        let tune = try Tune(branch: branch, slug: slug, title: slug, abcPath: abcURL.path)
        try await tune.save(on: app.db)
        // Every part points at the same pages, which is what the build produces today:
        // one PDF per `.abc` file, the whole multi-voice score, recorded against each
        // voice the file declares (#20 is what will make them differ).
        for name in ["Melody"] + extraParts {
            try await Part(tune: tune, name: name, svgPaths: svgPaths).save(on: app.db)
        }
    }
}
