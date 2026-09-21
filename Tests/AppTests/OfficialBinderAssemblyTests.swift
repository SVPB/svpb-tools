import CeolKitParser
import CeolKitSVGRenderer
import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// C4: after a build, the binders `binders.yaml` declares are assembled and written
/// to the branch's binder output directory.
///
/// The end-to-end cases drive `syncCatalogue` against a real git repository in a
/// temporary directory, the way `CatalogueReconciliationTests` does, because what is
/// being checked is the *wiring* — that the file read after conversion reaches the
/// assembler, and that what it produced is what the build reports. The assembler's own
/// page arithmetic is `BinderGenerationTests`'s subject; the direct cases here cover
/// only what is particular to an official binder: the mapping from `binders.yaml`, and
/// the fact that a tune contributes its pages once however many parts it has (#20).
final class OfficialBinderAssemblyTests: XCTestCase {

    var app: Application!
    var workspace: URL!
    var origin: URL!
    var service: BuildService!

    private let branch = "2026"

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("official-binder-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        origin = root.appendingPathComponent("origin", isDirectory: true)
        for url in [workspace!, origin!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try git(["init", "--initial-branch", branch], in: origin)

        service = BuildService(
            gitService: GitService(repoURL: origin.path, workspaceBase: workspace),
            boxService: app.boxService,
            slackService: app.slackService,
            binderService: app.binderService,
            musicWorkspacePath: workspace.path)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: origin.deletingLastPathComponent())
    }

    // MARK: - End to end

    /// The build's product. Two binders declared, two PDFs written under
    /// `output/<branch>/binders/`, and those filenames — not the per-tune
    /// intermediates — are what `Build.files` lists.
    func testDeclaredBindersAreAssembledAndReported() async throws {
        try commit([
            "march.abc": abc("Test March"),
            "reel.abc": abc("Test Reel"),
            "binders.yaml": Data("""
            binders:
              - name: "2026 Band Binder"
                output: 2026_binder.pdf
                sections:
                  - title: "Grade 4 Tunes"
                    entries:
                      - tune: march
                  - title: "Parade Tunes"
                    entries:
                      - tune: reel
              - name: "2026 Speculative"
                output: 2026_spec.pdf
                sections:
                  - title: "Speculative"
                    entries:
                      - tune: reel
            """.utf8),
        ])

        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)

        let build = try await onlyBuild()
        XCTAssertEqual(build.status, .success, "Nothing failed:\n\(build.log ?? "")")
        XCTAssertEqual(build.files.sorted(), ["2026_binder.pdf", "2026_spec.pdf"],
                       "Build.files lists the binders, not the per-tune intermediates")

        for name in ["2026_binder.pdf", "2026_spec.pdf"] {
            let url = await service.binderOutputDirectory(for: branch).appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            XCTAssertTrue(data.starts(with: Data("%PDF".utf8)), "\(name) is not a PDF")
        }
        // Two sections of one tune each: a divider apiece, and a page apiece.
        XCTAssertTrue(build.log?.contains("[binder] Assembled 2026_binder.pdf — 4 page(s)") ?? false,
                      "The log has to say what was assembled:\n\(build.log ?? "")")
    }

    /// A slug the catalogue cannot supply must cost a warning that names the binder
    /// it was dropped from, and must not leave the build looking green — a typo in
    /// `binders.yaml` otherwise costs a tune silently.
    func testAMissingTuneNamesItsBinderAndMakesTheBuildPartial() async throws {
        try commit([
            "march.abc": abc("Test March"),
            "binders.yaml": Data("""
            binders:
              - name: "2026 Band Binder"
                output: 2026_binder.pdf
                sections:
                  - title: "Grade 4 Tunes"
                    entries:
                      - tune: march
                      - tune: ghost_tune
            """.utf8),
        ])

        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)

        let build = try await onlyBuild()
        XCTAssertEqual(build.status, .partial)
        let log = build.log ?? ""
        XCTAssertTrue(log.contains("2026_binder.pdf is missing 'ghost_tune'"),
                      "The log has to name the binder that went to press without it:\n\(log)")
        XCTAssertEqual(build.files, ["2026_binder.pdf"],
                       "The binder is still produced — with the tunes that do resolve")
    }

    /// Dividers alone are not a binder. Nothing is written, so a previous good
    /// binder is not replaced by an empty one, and the build says why.
    func testABinderThatResolvesToNothingIsNotWritten() async throws {
        try commit([
            "march.abc": abc("Test March"),
            "binders.yaml": Data("""
            binders:
              - name: "All Typos"
                output: typos.pdf
                sections:
                  - title: "Nothing Here"
                    entries:
                      - tune: ghost_tune
            """.utf8),
        ])

        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)

        let build = try await onlyBuild()
        XCTAssertEqual(build.status, .partial)
        XCTAssertEqual(build.files, [], "A binder that assembled nothing was not produced")
        XCTAssertTrue(build.log?.contains("✗ typos.pdf could not be assembled") ?? false,
                      "The log has to say the binder failed:\n\(build.log ?? "")")
        let url = await service.binderOutputDirectory(for: branch).appendingPathComponent("typos.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A branch that has not been migrated to `binders.yaml` still converts. It has
    /// no official binders, which is not a failure.
    func testABranchWithNoBindersFileStillSucceeds() async throws {
        try commit(["march.abc": abc("Test March")])

        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)

        let build = try await onlyBuild()
        XCTAssertEqual(build.status, .success, build.log ?? "")
        XCTAssertEqual(build.files, [])
    }

    // MARK: - The official spec's own shape

    /// Per-part rendering is deferred past MVP (#20): every `Part` row of a tune
    /// points at the same pages, so an official entry contributes the tune's pages
    /// once — whatever `parts:` says, and however many parts the tune has.
    func testATuneWithSeveralPartsContributesItsPagesOnce() async throws {
        let branchRow = Branch(name: branch)
        try await branchRow.save(on: app.db)
        let tune = try Tune(branch: branchRow, slug: "march", title: "Test March",
                            abcPath: try seedABC("march").path)
        try await tune.save(on: app.db)
        let pages = try seedPages("march")
        for name in ["Melody", "Seconds"] {
            try await Part(tune: tune, name: name, svgPaths: pages).save(on: app.db)
        }

        let binder = try decodeBinder("""
        binders:
          - name: "One Tune"
            output: one.pdf
            sections:
              - title: "Only Section"
                entries:
                  - tune: march
                    parts: ["Melody", "Seconds"]
        """)
        let directory = workspace.appendingPathComponent("assembled", isDirectory: true)

        let assembly = try await app.binderService.assemble(
            binder, branch: branch, in: directory, db: app.db, logger: app.logger)

        XCTAssertEqual(assembly.pageCount, 2,
                       "One divider and the tune's single page — not the score once per part (#20)")
        XCTAssertEqual(assembly.missing, [])
        XCTAssertEqual(assembly.url, directory.appendingPathComponent("one.pdf"))
        XCTAssertTrue(try Data(contentsOf: assembly.url).starts(with: Data("%PDF".utf8)))
    }

    /// The spec `binders.yaml` maps onto: every section titled, so every section
    /// gets a divider, and no entry carries parts.
    func testOfficialBinderMapsOntoABinderSpec() throws {
        let binder = try decodeBinder("""
        binders:
          - name: "2026 Band Binder"
            output: 2026_binder.pdf
            sections:
              - title: "Grade 4 Tunes"
                entries:
                  - tune: march
                  - tune: reel
                    parts: ["Melody"]
        """)

        let spec = binder.spec(branch: "2026")

        XCTAssertEqual(spec.name, "2026 Band Binder")
        XCTAssertEqual(spec.branch, "2026")
        XCTAssertEqual(spec.sections.map(\.titlePage), ["Grade 4 Tunes"])
        XCTAssertEqual(spec.entries.map(\.tuneSlug), ["march", "reel"])
        XCTAssertEqual(spec.entries.map(\.parts), [[], []],
                       "An official entry asks for the tune, not for parts of it (#20)")
    }

    // MARK: - Fixtures

    private func abc(_ title: String) -> Data {
        Data("""
        %abc-2.2
        %%footer "$P"
        X:1
        T:\(title)
        M:4/4
        L:1/8
        K:D
        ABcd efga | gfed cBAG |]
        """.utf8)
    }

    private func decodeBinder(_ yaml: String) throws -> OfficialBinder {
        let file = try BinderDefinitionLoader.decode(yaml)
        return try XCTUnwrap(file.binders.first)
    }

    /// Writes a tune's ABC into the workspace and returns where it landed.
    private func seedABC(_ slug: String) throws -> URL {
        let url = workspace.appendingPathComponent("\(slug).abc")
        try abc(slug).write(to: url)
        return url
    }

    /// Engraves the seeded tune and returns its page paths, as a build would record them.
    private func seedPages(_ slug: String) throws -> [String] {
        let source = try String(contentsOf: workspace.appendingPathComponent("\(slug).abc"),
                                encoding: .utf8)
        let parsed = CeolKitParser().parse(source, options: .default)
        let svgs = try SVGRenderer(config: .init(pageSize: .letter)).render(parsed.score)
        return try svgs.enumerated().map { index, svg in
            let url = workspace.appendingPathComponent(String(format: "%@%03d.svg", slug, index))
            try svg.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
    }

    // MARK: - Helpers

    private func commit(_ files: [String: Data], message: String = "fixture") throws {
        for (name, contents) in files {
            try contents.write(to: origin.appendingPathComponent(name))
        }
        try git(["add", "--all"], in: origin)
        try git(["commit", "--message", message], in: origin)
    }

    /// Runs git with an identity and signing settings of its own, so the fixture
    /// repository does not depend on whatever the machine has configured.
    private func git(_ args: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "user.name=Test",
            "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false",
        ] + args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("git \(args.joined(separator: " ")) failed: "
                          + (String(data: output, encoding: .utf8) ?? ""))
        }
    }

    private func onlyBuild() async throws -> Build {
        let builds = try await Build.query(on: app.db).all()
        XCTAssertEqual(builds.count, 1, "Expected exactly one build")
        return try XCTUnwrap(builds.first)
    }
}
