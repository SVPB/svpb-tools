import CeolKitParser
import CeolKitSVGRenderer
import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// Drives `BinderService` against a seeded catalogue: every tune page in order,
/// with a divider page ahead of each titled section that has something in it.
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

    /// Tune pages by slug (each seeded tune is one page), dividers by title.
    private func describe(_ pages: [BinderService.Page]) -> [String] {
        pages.map { page in
            switch page {
            case .tune(let path):
                URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            case .divider(let title, let svg):
                svg.contains("divider-title") ? "divider: \(title)" : "malformed divider: \(title)"
            }
        }
    }

    /// Engraves a one-page tune, writes it where the build would, and records it
    /// in the catalogue.
    private func seedTune(_ slug: String, branch: Branch) async throws {
        let abc = """
        X:1
        T:\(slug)
        M:4/4
        L:1/8
        K:D
        ABcd efga | gfed cBAG | ABcd efga | g2 f2 e2 d2 |]
        """
        let parsed = CeolKitParser().parse(abc, options: .default)
        let svgs = try SVGRenderer(config: .init(pageSize: .letter)).render(parsed.score)
        XCTAssertEqual(svgs.count, 1, "Seed tune should be a single page")

        let url = workspace.appendingPathComponent("\(slug).svg")
        try XCTUnwrap(svgs.first).write(to: url, atomically: true, encoding: .utf8)

        let tune = try Tune(branch: branch, slug: slug, title: slug)
        try await tune.save(on: app.db)
        try await Part(tune: tune, name: "Melody", svgPaths: [url.path]).save(on: app.db)
    }
}
