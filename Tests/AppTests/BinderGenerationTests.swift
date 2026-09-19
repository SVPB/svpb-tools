import CeolKitParser
import CeolKitSVGRenderer
import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// Drives `BinderService` against a seeded catalogue: every tune page in order,
/// with a divider page ahead of each titled section that has something in it,
/// and every page numbered by its position in the binder rather than in its tune.
final class BinderGenerationTests: XCTestCase {

    var app: Application!
    var workspace: URL!
    var service: BinderService!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binder-generation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        service = BinderService(musicWorkspacePath: workspace.path)

        let branch = Branch(name: "2026")
        try await branch.save(on: app.db)
        for slug in ["march", "reel", "jig"] {
            try await seedTune(slug, branch: branch)
        }
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: workspace)
    }

    func testTitledSectionsGetDividerPages() async throws {
        let spec = BinderSpec(name: "Sections", branch: "2026", sections: [
            // Untitled: no divider, just the tune.
            BinderSection(title: nil, entries: [entry("march")]),
            // Titled: a divider, then both tunes.
            BinderSection(title: "Parade Set", entries: [entry("reel"), entry("jig")]),
            // Titled but empty, and titled with nothing that resolves: no orphan dividers.
            BinderSection(title: "Nothing Here", entries: []),
            BinderSection(title: "Gone", entries: [entry("no_such_tune")]),
            // A blank title is no title.
            BinderSection(title: "  ", entries: [entry("march")]),
        ])

        let pages = try await service.pages(for: spec, requestID: UUID(), db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["march", "divider: Parade Set", "reel", "jig", "march"])
    }

    /// A binder stored in the flat shape assembles exactly as it did before.
    func testFlatSpecHasNoDividers() async throws {
        let json = #"{"name":"Old","branch":"2026","entries":[{"tune_slug":"jig","parts":["Melody"]},{"tune_slug":"reel","parts":["Melody"]}]}"#
        let spec = try JSONDecoder().decode(BinderSpec.self, from: Data(json.utf8))

        let pages = try await service.pages(for: spec, requestID: UUID(), db: app.db, logger: app.logger)
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

        let pages = try await service.pages(for: spec, requestID: UUID(), db: app.db, logger: app.logger)
        XCTAssertEqual(printedPageNumbers(pages), [1, 2, 3])
    }

    /// A divider is a sheet of paper, so the tune behind it is numbered as though it
    /// were one — the number has to match what a reader counts, not what a renderer
    /// happens to have drawn.
    func testDividerPagesAreCountedEvenThoughTheyPrintNoNumber() async throws {
        let spec = BinderSpec(name: "Divided", branch: "2026", sections: [
            BinderSection(title: "Parade Set", entries: [entry("march")]),
            BinderSection(title: "Slow Airs", entries: [entry("reel")]),
        ])

        let pages = try await service.pages(for: spec, requestID: UUID(), db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages),
                       ["divider: Parade Set", "march", "divider: Slow Airs", "reel"])
        // Pages 1 and 3 are the dividers; the tunes behind them are 2 and 4.
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

        let pages = try await service.pages(for: spec, requestID: UUID(), db: app.db, logger: app.logger)
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

        let pages = try await service.pages(for: spec, requestID: UUID(), db: app.db, logger: app.logger)
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

    // MARK: - Helpers

    private func entry(_ slug: String) -> BinderEntry {
        BinderEntry(tuneSlug: slug, parts: ["Melody"])
    }

    /// Tune pages by slug, dividers by title, so a test reads as the binder's contents.
    private func describe(_ pages: [BinderService.Page]) -> [String] {
        pages.map { page in
            switch page {
            case .tune(let slug, _):
                slug
            case .prebuilt(let slug, _):
                "prebuilt: \(slug)"
            case .divider(let title, let svg):
                svg.contains("divider-title") ? "divider: \(title)" : "malformed divider: \(title)"
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
    private func seedTune(_ slug: String, branch: Branch, pages: Int = 1) async throws {
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
        try await Part(tune: tune, name: "Melody", svgPaths: svgPaths).save(on: app.db)
    }
}
