import CeolKitParser
import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// A build reconciles the catalogue with the working tree instead of emptying it
/// and refilling it.
///
/// The end-to-end cases drive `syncCatalogue` against a real git repository in a
/// temporary directory — the one part of `BuildService` that used to be untestable
/// is cheap to arrange once the "remote" is a local path — because the bug this
/// covers (#22) was in the *order* of the pipeline's steps, not in any one of them.
final class CatalogueReconciliationTests: XCTestCase {

    var app: Application!
    /// Where the service checks branches out and writes its output.
    var workspace: URL!
    /// The fixture repository the service clones from.
    var origin: URL!
    var service: BuildService!

    private let branch = "2026"

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catalogue-reconciliation-\(UUID().uuidString)", isDirectory: true)
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

    /// The bug: the catalogue was cleared before conversion, so a file that threw
    /// — here one that is not UTF-8, and sorts first — left the branch with an
    /// empty catalogue and `/binder-builder` with nothing to offer.
    func testAFailedBuildLeavesThePreviousCatalogueIntact() async throws {
        try commit(["march.abc": Data(Self.marchABC.utf8)])
        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)
        try await assertCatalogue(is: ["march"])
        let firstBuilds = try await buildIDs()

        // 0xFF is not valid UTF-8, so reading the file throws before anything in
        // the loop has upserted a thing.
        try commit(["aaa-unreadable.abc": Data([0xFF, 0xFE, 0x41])])
        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)

        let failed = try await newBuild(since: firstBuilds)
        XCTAssertEqual(failed.status, .failure)
        try await assertCatalogue(is: ["march"], "A build that threw must not take the catalogue with it")
        let parts = try await parts(of: "march")
        XCTAssertEqual(parts.map(\.name), [CatalogueExtractor.fullScorePartName])
        XCTAssertNotNil(parts.first?.pdfPath, "The surviving entry still points at the PDF the last build made")
    }

    /// The other half of reconciling: a tune whose source file has left the tree
    /// goes, so a successful build is still the whole truth about the branch.
    func testATuneWhoseFileHasGoneIsRemoved() async throws {
        try commit(["march.abc": Data(Self.marchABC.utf8),
                    "reel.abc": Data(Self.reelABC.utf8)])
        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)
        try await assertCatalogue(is: ["march", "reel"])
        let partsBefore = try await Part.query(on: app.db).count()
        XCTAssertEqual(partsBefore, 2)

        try remove("reel.abc")
        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)

        try await assertCatalogue(is: ["march"])
        let partsAfter = try await Part.query(on: app.db).count()
        XCTAssertEqual(partsAfter, 1, "The removed tune's parts went with it")
    }

    /// A tree with no music in it is far likelier to be a bad checkout than a
    /// branch that has genuinely lost every tune, so the rows stay and the build
    /// says so.
    func testAnEmptyWorkingTreeKeepsTheCatalogue() async throws {
        try commit(["march.abc": Data(Self.marchABC.utf8)])
        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)
        let firstBuilds = try await buildIDs()

        try remove("march.abc")
        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)

        let build = try await newBuild(since: firstBuilds)
        XCTAssertEqual(build.status, .partial)
        XCTAssertTrue(build.log?.contains("No .abc files in the tree") ?? false,
                      "The log has to name what was kept and why:\n\(build.log ?? "")")
        try await assertCatalogue(is: ["march"])
    }

    // MARK: - Catalogue entries

    /// Nothing clears the catalogue before conversion any more, so a voice a file
    /// has stopped declaring has to be deleted where the file is upserted — or a
    /// binder would go on offering a part the arrangement no longer has.
    func testUpsertRemovesPartsTheFileNoLongerDeclares() async throws {
        let branchRow = Branch(name: branch)
        try await branchRow.save(on: app.db)
        let tune = try Tune(branch: branchRow, slug: "march", title: "Old Title")
        try await tune.save(on: app.db)
        try await Part(tune: tune, name: "Melody", pdfPath: "/old/march.pdf").save(on: app.db)
        try await Part(tune: tune, name: "Bass", pdfPath: "/old/march.pdf").save(on: app.db)

        try await service.upsertCatalogueEntry(
            branch: branch,
            stem: "march",
            abcPath: "/tree/march.abc",
            parsed: CeolKitParser().parse(Self.twoVoiceABC, options: .default),
            pdfPath: "/new/march.pdf",
            svgPaths: ["/new/march000.svg"],
            db: app.db)

        let parts = try await self.parts(of: "march")
        XCTAssertEqual(parts.map(\.name).sorted(), ["Harmony 1", "Melody"],
                       "'Bass' is no longer in the file, so it is no longer a part")
        XCTAssertEqual(Set(parts.map(\.pdfPath)), ["/new/march.pdf"])
        let stored = try await Tune.query(on: app.db)
            .filter(\.$branch.$id == branch).filter(\.$slug == "march").first()
        let updated = try XCTUnwrap(stored)
        XCTAssertEqual(updated.title, "Multi Voice")
        XCTAssertEqual(updated.abcPath, "/tree/march.abc")
    }

    /// Pruning is scoped to the branch that built — the same slug on another
    /// branch is a different arrangement, and no business of this build's.
    func testPruningTouchesNoOtherBranch() async throws {
        try await seed(branch: "2026", tunes: ["march", "reel"])
        try await seed(branch: "2027", tunes: ["march", "reel"])

        let pruned = try await service.pruneCatalogue(
            branch: "2026", keeping: ["march"], db: app.db)

        XCTAssertEqual(pruned.tunes, ["reel"])
        XCTAssertEqual(pruned.parts, 1)
        try await assertCatalogue(is: ["march"], branch: "2026")
        try await assertCatalogue(is: ["march", "reel"], branch: "2027")
        let remainingParts = try await Part.query(on: app.db).count()
        XCTAssertEqual(remainingParts, 3)
    }

    // MARK: - Fixtures

    private static let marchABC = """
    X:1
    T:Test March
    M:4/4
    L:1/8
    K:D
    A2 d2 f2 a2 | f2 d2 A4 |]
    """

    private static let reelABC = """
    X:1
    T:Test Reel
    M:4/4
    L:1/8
    K:A
    A2 B2 c2 d2 | e2 c2 A4 |]
    """

    private static let twoVoiceABC = """
    X:1
    T:Multi Voice
    M:4/4
    L:1/8
    V:1 name="Melody"
    V:2 nm="Harmony 1"
    K:D
    V:1
    A2 d2 |]
    V:2
    F2 A2 |]
    """

    // MARK: - Helpers

    /// Writes `files` into the fixture repository and commits them.
    private func commit(_ files: [String: Data], message: String = "fixture") throws {
        for (name, contents) in files {
            try contents.write(to: origin.appendingPathComponent(name))
        }
        try git(["add", "--all"], in: origin)
        try git(["commit", "--message", message], in: origin)
    }

    private func remove(_ name: String) throws {
        try git(["rm", name], in: origin)
        try git(["commit", "--message", "remove \(name)"], in: origin)
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

    private func seed(branch name: String, tunes: [String]) async throws {
        let row: Branch
        if let existing = try await Branch.find(name, on: app.db) {
            row = existing
        } else {
            row = Branch(name: name)
            try await row.save(on: app.db)
        }
        for slug in tunes {
            let tune = try Tune(branch: row, slug: slug, title: slug)
            try await tune.save(on: app.db)
            try await Part(tune: tune, name: "Melody").save(on: app.db)
        }
    }

    private func assertCatalogue(
        is slugs: [String], branch name: String? = nil, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let found = try await Tune.query(on: app.db)
            .filter(\.$branch.$id == (name ?? branch))
            .all()
            .map(\.slug)
            .sorted()
        XCTAssertEqual(found, slugs.sorted(), message, file: file, line: line)
    }

    private func parts(of slug: String) async throws -> [Part] {
        let tune = try await Tune.query(on: app.db)
            .filter(\.$branch.$id == branch)
            .filter(\.$slug == slug)
            .first()
        guard let tune else { return [] }
        return try await Part.query(on: app.db)
            .filter(\.$tune.$id == tune.requireID())
            .all()
    }

    private func buildIDs() async throws -> Set<UUID> {
        Set(try await Build.query(on: app.db).all().compactMap(\.id))
    }

    /// The build this second sync created. `triggered` timestamps can tie, so the
    /// builds are told apart by identity rather than by time.
    private func newBuild(since existing: Set<UUID>) async throws -> Build {
        let builds = try await Build.query(on: app.db).all()
            .filter { $0.id.map { !existing.contains($0) } ?? false }
        XCTAssertEqual(builds.count, 1, "Expected exactly one new build")
        return try XCTUnwrap(builds.first)
    }
}
