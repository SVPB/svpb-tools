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

    // MARK: - Table of contents (#47)

    /// The listing names what the binder holds and where each of it starts, and
    /// its own pages are counted into every number after them.
    ///
    /// A title page standing over tunes is a section and is listed. The cover is
    /// a title page standing over nothing, so it introduces nothing and is not.
    func testContentsListsTheBinderAndIsCountedIntoItsNumbers() async throws {
        let spec = BinderSpec(name: "2027 Band Binder", branch: "2026", sections: [
            BinderSection(title: ["SVPB Music", "2027"], entries: []),
            BinderSection(title: nil, entries: [], toc: TableOfContentsSpec()),
            BinderSection(title: "G4 Tunes", entries: [entry("march"), entry("reel")]),
            BinderSection(title: "Slow Airs", entries: [entry("jig")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), [
            "title: SVPB Music / 2027",
            "contents: [G4 Tunes 3, >march 4, >reel 5, Slow Airs 6, >jig 7]",
            "title: G4 Tunes",
            "march",
            "reel",
            "title: Slow Airs",
            "jig",
        ])
        // The cover and the contents are paper too: the first tune opens on 4.
        XCTAssertEqual(printedPageNumbers(pages), [4, 5, 7])
    }

    /// A contents page is not numbered, any more than a title page is — and it
    /// is not a tune page either, so a binder of contents alone is no binder.
    func testContentsIsNotATunePage() async throws {
        let spec = BinderSpec(name: "Contents only", branch: "2026", sections: [
            BinderSection(title: nil, entries: [], toc: TableOfContentsSpec()),
            BinderSection(title: "Gone", entries: [entry("no_such_tune")]),
        ])
        let request = BinderRequest(definition: spec)
        try await request.save(on: app.db)

        await service.generateBinder(requestID: try request.requireID(), db: app.db, logger: app.logger)

        let reloaded = try await BinderRequest.find(request.id, on: app.db)
        XCTAssertNil(reloaded?.pdfPath, "A binder of contents pages alone was produced")
    }

    /// The listing is built from the pages the binder actually got, so a tune
    /// that did not resolve is not listed — and neither is the title over a
    /// section that lost all of its tunes.
    func testUnresolvedTunesAreLeftOutOfTheListing() async throws {
        let spec = BinderSpec(name: "Gaps", branch: "2026", sections: [
            BinderSection(title: nil, entries: [], toc: TableOfContentsSpec()),
            BinderSection(title: "Present", entries: [entry("no_such_tune"), entry("march")]),
            BinderSection(title: "Absent", entries: [entry("also_missing")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), [
            "contents: [Present 2, >march 3]",
            "title: Present",
            "march",
        ])
    }

    /// A tune is listed by its title, and by its slug where the ABC gave none.
    func testTunesAreListedByTitleFallingBackToSlug() async throws {
        try await seedTune("stb", branch: branch, title: "Scotland the Brave")
        try await seedTune("untitled_tune", branch: branch, untitled: true)

        let spec = BinderSpec(name: "Names", branch: "2026", sections: [
            BinderSection(title: nil, entries: [], toc: TableOfContentsSpec()),
            BinderSection(title: nil, entries: [entry("stb"), entry("untitled_tune")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(contents(pages).first?.map(\.text), ["Scotland the Brave", "untitled_tune"])
    }

    /// `include:` narrows what is listed. With no sections in the listing there
    /// is nothing for the tunes to sit under, so they are set flush left — which
    /// is also what a binder with no titled sections gets.
    func testAListingCanNameTunesOnly() async throws {
        let spec = BinderSpec(name: "Tunes only", branch: "2026", sections: [
            BinderSection(title: nil, entries: [], toc: TableOfContentsSpec(include: [.tunes])),
            BinderSection(title: "G4 Tunes", entries: [entry("march")]),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["contents: [march 3]", "title: G4 Tunes", "march"])
        XCTAssertEqual(contents(pages).first?.first?.level, 0, "A tune with no section over it is still indented")
    }

    /// A listing too long for one page takes a second, and the second page's
    /// worth of paper is counted into the numbering like the first's.
    func testALongListingReservesEveryPageItNeeds() async throws {
        let renderer = TableOfContentsRenderer()
        // Two lines per section — its title and its one tune — so this is the
        // smallest binder whose listing does not fit on one page.
        let sectionCount = renderer.linesOnFirstPage / 2 + 1
        let spec = BinderSpec(name: "Long", branch: "2026", sections:
            [BinderSection(title: nil, entries: [], toc: TableOfContentsSpec())]
            + (1 ... sectionCount).map {
                BinderSection(title: BinderTitle(["Set \($0)"]), entries: [entry("march")])
            })

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        let listings = contents(pages)

        XCTAssertEqual(listings.count, 2, "The listing did not reserve a second page")
        XCTAssertEqual(listings[0].count, renderer.linesOnFirstPage)
        XCTAssertEqual(listings[1].count, sectionCount * 2 - renderer.linesOnFirstPage)
        XCTAssertEqual(pages.count, 2 + sectionCount * 2)
        // Two contents pages ahead of it, so "Set 1" opens on 3 and its tune on 4.
        XCTAssertEqual(listings[0].first, .init(text: "Set 1", level: 0, page: 3))
        XCTAssertEqual(listings[0].dropFirst().first, .init(text: "march", level: 1, page: 4))
        XCTAssertEqual(printedPageNumbers(pages).first, 4)
    }

    /// A binder may declare more than one, and each says the same thing: every
    /// listing covers the whole binder, wherever in it the pages sit.
    func testEveryListingCoversTheWholeBinder() async throws {
        let spec = BinderSpec(name: "Twice", branch: "2026", sections: [
            BinderSection(title: nil, entries: [], toc: TableOfContentsSpec()),
            BinderSection(title: "Set", entries: [entry("march")]),
            BinderSection(title: nil, entries: [], toc: TableOfContentsSpec()),
        ])

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        let listings = contents(pages)
        XCTAssertEqual(listings.count, 2)
        XCTAssertEqual(listings[0], listings[1])
        // Both pages are counted, and the second one is itself page 4.
        XCTAssertEqual(listings[0], [.init(text: "Set", level: 0, page: 2),
                                     .init(text: "march", level: 1, page: 3)])
        XCTAssertEqual(pages.count, 4)
    }

    /// A contents section carrying a title is headed with it; one without is
    /// headed "Contents". Either way it is a heading, not a title page.
    func testTheHeadingComesFromTheSectionTitle() async throws {
        for (title, heading) in [(BinderTitle?.none, "Contents"), (BinderTitle("What's Inside"), "What's Inside")] {
            let spec = BinderSpec(name: "Headed", branch: "2026", sections: [
                BinderSection(title: title, entries: [], toc: TableOfContentsSpec()),
                BinderSection(title: nil, entries: [entry("march")]),
            ])
            let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
            XCTAssertEqual(describe(pages), ["contents: [march 2]", "march"],
                           "A contents section drew a title page of its own")
            guard case .contents(_, let svg) = pages[0] else { return XCTFail("Not a contents page") }
            let outlined = try TextOutliner.outline(heading, face: .libertinusSerifRegular, fontSize: 24)
            XCTAssertTrue(svg.contains(outlined.svg), "The page is not headed '\(heading)'")
        }
    }

    // MARK: - Packing (#48)

    /// The saving the issue is about: three tunes that each took a page of their own come
    /// back sharing one, and a binder that never asked stays exactly as it was.
    func testPackingPutsShortTunesOnOneSheet() async throws {
        let sections = [BinderSection(title: nil,
                                      entries: [entry("march"), entry("reel"), entry("jig")])]

        let loose = try await service.pages(
            for: BinderSpec(name: "Loose", branch: "2026", sections: sections),
            label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(loose), ["march", "reel", "jig"])

        let packed = try await service.pages(
            for: BinderSpec(name: "Packed", branch: "2026", sections: sections, pack: true),
            label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(packed), ["march + reel + jig"])
        XCTAssertEqual(printedPageNumbers(packed), [1])
    }

    /// The override: one tune says it must open a page, and the run stops ahead of it. The
    /// tunes on either side of the break still pack among themselves.
    func testBreakBeforeOpensAPageOfItsOwn() async throws {
        let spec = BinderSpec(name: "Broken", branch: "2026", sections: [
            BinderSection(title: nil, entries: [
                entry("march"),
                BinderEntry(tuneSlug: "reel", parts: ["Melody"], pageBreak: .before),
                entry("jig"),
            ]),
        ], pack: true)

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["march", "reel + jig"])
        XCTAssertEqual(printedPageNumbers(pages), [1, 2])
    }

    /// A title page owns a page anyway, so it ends the run ahead of it — which costs
    /// nothing, and keeps a section's tunes from climbing onto the sheet before its title.
    func testATitlePageEndsTheRun() async throws {
        let spec = BinderSpec(name: "Sectioned", branch: "2026", sections: [
            BinderSection(title: nil, entries: [entry("march")]),
            BinderSection(title: "Second Set", entries: [entry("reel"), entry("jig")]),
        ], pack: true)

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["march", "title: Second Set", "reel + jig"])
        // The title page is paper: the packed run after it opens on 3.
        XCTAssertEqual(printedPageNumbers(pages), [1, 3])
    }

    /// The reason #48 needed CeolKit to report where a tune landed: under packing the page
    /// a tune starts on is not index arithmetic any more, and a table of contents that
    /// guessed would point at the wrong sheet. Every listed tune names the page its music
    /// is actually printed on.
    func testTheContentsAgreeWithThePackedPages() async throws {
        let found = try await Branch.find("2026", on: app.db)
        try await seedTune("tall", branch: try XCTUnwrap(found), pages: 2)

        let spec = BinderSpec(name: "Listed", branch: "2026", sections: [
            BinderSection(title: nil, entries: [], toc: TableOfContentsSpec(include: [.tunes])),
            BinderSection(title: nil, entries: [entry("march"), entry("reel"),
                                                entry("tall"), entry("jig")]),
        ], pack: true)

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        let listing = try XCTUnwrap(contents(pages).first)

        XCTAssertEqual(listing.map(\.text), ["march", "reel", "tall", "jig"])
        for line in listing {
            let page = try XCTUnwrap(pages[safe: line.page - 1],
                                     "the contents send a reader to page \(line.page), which the binder does not have")
            XCTAssertTrue(page.slugs.contains(line.text),
                          "the contents send a reader to page \(line.page) for '\(line.text)', which is not on it")
            // And the sheet itself prints that number, which is what a reader turns to.
            guard case .tune(_, let svg) = page,
                  let match = svg.firstMatch(of: /ceolkit-meta: \{"page": (\d+)/) else {
                return XCTFail("Page \(line.page) is not an engraved tune page")
            }
            XCTAssertEqual(Int(match.1), line.page)
        }
        // Two short tunes ahead of a two-page one: the listing is not four consecutive pages.
        XCTAssertLessThan(pages.count, 1 + 5)
    }

    /// A tune with no ABC to re-engrave arrives as whole pages the build already made, so
    /// it cannot join a run. It is engraved alone and the tunes around it still pack.
    func testATuneWithNoABCIsNotPackedButItsNeighboursAre() async throws {
        let found = try await Tune.query(on: app.db).filter(\.$slug == "reel").first()
        let tune = try XCTUnwrap(found)
        tune.abcPath = nil
        try await tune.save(on: app.db)

        let spec = BinderSpec(name: "Mixed", branch: "2026", sections: [
            BinderSection(title: nil, entries: [entry("reel"), entry("march"), entry("jig")]),
        ], pack: true)

        let pages = try await service.pages(for: spec, label: "test", db: app.db, logger: app.logger)
        XCTAssertEqual(describe(pages), ["prebuilt: reel", "march + jig"])
    }

    /// An official binder carries the choice through from `binders.yaml`, entry overrides
    /// and all — the mapping onto the personal spec is the only place it could be lost.
    func testAnOfficialBinderCarriesPackingThrough() {
        let binder = OfficialBinder(name: "Band", output: "band.pdf", sections: [
            OfficialBinderSection(title: "Set", entries: [
                OfficialBinderEntry(tune: "march"),
                OfficialBinderEntry(tune: "reel", pageBreak: .before),
            ]),
        ], pack: true)

        let spec = binder.spec(branch: "2026")
        XCTAssertTrue(spec.pack)
        XCTAssertEqual(spec.entries.map(\.breaksBefore), [false, true])
    }

    // MARK: - Helpers

    /// The lines each contents page carries, in binder order.
    private func contents(_ pages: [BinderService.Page]) -> [[TableOfContentsRenderer.Entry]] {
        pages.compactMap { page in
            guard case .contents(let entries, _) = page else { return nil }
            return entries
        }
    }

    private func entry(_ slug: String) -> BinderEntry {
        BinderEntry(tuneSlug: slug, parts: ["Melody"])
    }

    /// Tune pages by slug, title pages by their text, contents pages by the lines
    /// they carry, so a test reads as the binder's contents.
    ///
    /// A page names the tunes that *open* on it, so a tune running over several pages
    /// names itself only on the first: the rest are described as the tune they carry on
    /// from, which is what a reader of the list wants to see. A packed page (#48) that
    /// two tunes share names both.
    private func describe(_ pages: [BinderService.Page]) -> [String] {
        var carried = ""
        return pages.map { page in
            switch page {
            case .tune(let slugs, _):
                if !slugs.isEmpty { carried = slugs.joined(separator: " + ") }
                return carried
            case .prebuilt(let slug, _):
                carried = slug
                return "prebuilt: \(slug)"
            case .titlePage(let title, let svg):
                return svg.contains("title-page")
                    ? "title: \(title.display)" : "malformed title: \(title.display)"
            case .contents(let entries, let svg):
                return svg.contains("table-of-contents")
                    ? "contents: [\(entries.map { "\(String(repeating: ">", count: $0.level))\($0.text) \($0.page)" }.joined(separator: ", "))]"
                    : "malformed contents"
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
                          title: String? = nil, untitled: Bool = false,
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

        // A catalogued tune is titled from its ABC `T:` header, which is the slug
        // here unless a test asks for something else; `untitled` is the tune whose
        // file carried no title at all.
        let tune = try Tune(branch: branch, slug: slug,
                            title: untitled ? nil : (title ?? slug),
                            abcPath: abcURL.path)
        try await tune.save(on: app.db)
        // Every part points at the same pages, which is what the build produces today:
        // one PDF per `.abc` file, the whole multi-voice score, recorded against each
        // voice the file declares (#20 is what will make them differ).
        for name in ["Melody"] + extraParts {
            try await Part(tune: tune, name: name, svgPaths: svgPaths).save(on: app.db)
        }
    }
}

// MARK: -

private extension Collection {
    /// The element at `index`, or `nil` where there is none — so a test that reads a page
    /// number back out of a contents line fails rather than traps when the number is wrong.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
