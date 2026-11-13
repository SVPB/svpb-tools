import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// O6: a binder that could not reach the destination is retained locally and sent on the
/// next build.
///
/// The builds publish to a `StubDestination`, which starts out refusing everything — the
/// shape of a Box outage — and can be told to let some or all binders through, so the
/// tests are offline and can watch a held-over binder go up as well as fail again (#85).
/// What is asserted is the record: which binders are outstanding, and what the next build
/// does about them.
final class BoxRetryTests: XCTestCase {

    var app: Application!
    var workspace: URL!
    var origin: URL!
    var service: BuildService!
    var destination: StubDestination!

    private let branch = "2026"

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("box-retry-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        origin = root.appendingPathComponent("origin", isDirectory: true)
        for url in [workspace!, origin!] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try git(["init", "--initial-branch", branch], in: origin)

        destination = StubDestination(failsEverything: true)
        service = BuildService(
            gitService: GitService(repoURL: origin.path, workspaceBase: workspace),
            destination: destination,
            slackService: app.slackService,
            binderService: app.binderService,
            musicWorkspacePath: workspace.path)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: origin.deletingLastPathComponent())
    }

    // MARK: - The record

    /// A build whose upload failed has to leave behind what failed, or the next build
    /// can only re-upload everything or nothing.
    func testAFailedUploadIsRecordedAsOutstanding() async throws {
        try commit(["march.abc": Self.abc, "binders.yaml": binders(output: "2026_binder.pdf")])

        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        let build = try await latestBuild()
        XCTAssertEqual(build.status, .partial, "An upload that never happened is not a success")
        XCTAssertTrue(build.log?.contains("✗ Upload failed for 2026_binder.pdf") ?? false,
                      build.log ?? "")

        let pending = try await outstanding()
        let row = try XCTUnwrap(pending.first)
        XCTAssertEqual(row.filename, "2026_binder.pdf")
        XCTAssertEqual(row.attempts, 1)
        XCTAssertNil(row.uploadedAt)
        XCTAssertNotNil(row.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.localPath),
                      "The artefact is retained locally — that is what makes a retry possible")
    }

    /// The retry itself: a binder this build is not rebuilding is picked up, attempted
    /// again, and — failing again — left outstanding with the attempt counted.
    func testABinderHeldOverFromAnEarlierBuildIsRetried() async throws {
        try commit(["march.abc": Self.abc, "binders.yaml": binders(output: "2026_binder.pdf")])
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        // The next build declares a different binder, so the first one is not reassembled
        // and can only be published through the retry pass.
        try commit(["binders.yaml": binders(output: "2026_spec.pdf")], message: "rename")
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        let build = try await latestBuild()
        let log = build.log ?? ""
        XCTAssertTrue(log.contains("1 binder(s) held over from an earlier build"), log)
        XCTAssertTrue(log.contains("✗ 2026_binder.pdf failed again"), log)

        let rows = try await outstanding()
        XCTAssertEqual(rows.map(\.filename), ["2026_binder.pdf", "2026_spec.pdf"])
        let heldOver = try XCTUnwrap(rows.first)
        XCTAssertEqual(heldOver.attempts, 2, "The second build tried it again")
    }

    /// A pending binder whose file has gone is dropped rather than retried forever —
    /// whatever rebuilt it owns it now.
    func testAnOutstandingBinderWhoseFileIsGoneIsDropped() async throws {
        try commit(["march.abc": Self.abc, "binders.yaml": binders(output: "2026_binder.pdf")])
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        let pending = try await outstanding()
        let row = try XCTUnwrap(pending.first)
        try FileManager.default.removeItem(atPath: row.localPath)

        try commit(["binders.yaml": binders(output: "2026_spec.pdf")], message: "rename")
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        let log = try await latestBuild().log ?? ""
        XCTAssertTrue(log.contains("2026_binder.pdf is no longer on disk as assembled; dropping it"), log)
        let rows = try await outstanding()
        XCTAssertEqual(rows.map(\.filename), ["2026_spec.pdf"])
    }

    /// The same, for a file that is still there but is no longer the one the row
    /// describes: uploading those bytes under this row would publish the wrong version.
    func testAnOutstandingBinderWhoseBytesChangedIsDropped() async throws {
        try commit(["march.abc": Self.abc, "binders.yaml": binders(output: "2026_binder.pdf")])
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        let pending = try await outstanding()
        let row = try XCTUnwrap(pending.first)
        try Data("not the binder any more".utf8).write(to: URL(fileURLWithPath: row.localPath))

        try commit(["binders.yaml": binders(output: "2026_spec.pdf")], message: "rename")
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        let log = try await latestBuild().log ?? ""
        XCTAssertTrue(log.contains("2026_binder.pdf is no longer on disk as assembled"), log)
        let remaining = try await outstanding().map(\.filename)
        XCTAssertEqual(remaining, ["2026_spec.pdf"])
    }

    /// Reassembling a binder resets its record: the row is about the file on disk now,
    /// not the one a previous build wrote.
    func testReassemblingABinderResetsItsRecord() async throws {
        try commit(["march.abc": Self.abc, "binders.yaml": binders(output: "2026_binder.pdf")])
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        let pending = try await outstanding()
        let first = try XCTUnwrap(pending.first)
        first.uploadedAt = Date()
        first.lastError = "stale"
        try await first.save(on: app.db)

        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        let rows = try await BinderUpload.query(on: app.db).all()
        XCTAssertEqual(rows.count, 1, "One row per binder per branch, carried across builds")
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.uploadedAt)
        XCTAssertEqual(row.attempts, 1, "Reset by the rebuild, then bumped by this build's attempt")
    }

    // MARK: - Recovery

    /// When the destination is back, the held-over binder goes up with the next build,
    /// is stamped as delivered, and is named in the build's log as a catch-up.
    func testAHeldOverBinderIsPublishedOnceTheDestinationIsBack() async throws {
        try commit(["march.abc": Self.abc, "binders.yaml": binders(output: "2026_binder.pdf")])
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        await destination.fail([])
        try commit(["binders.yaml": binders(output: "2026_spec.pdf")], message: "rename")
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        let log = try await latestBuild().log ?? ""
        XCTAssertTrue(log.contains("[publish] Uploaded 2026_spec.pdf to Stub"), log)
        XCTAssertTrue(log.contains("Uploaded 2026_binder.pdf to Stub, held over from an earlier build"), log)
        let published = await destination.published
        XCTAssertEqual(published, ["2026_spec.pdf", "2026_binder.pdf"],
                       "This build's binder first, then the one held over")

        let pending = try await outstanding()
        XCTAssertEqual(pending.map(\.filename), [], "Nothing is left outstanding")
        let rows = try await BinderUpload.query(on: app.db).sort(\.$filename).all()
        let heldOver = try XCTUnwrap(rows.first { $0.filename == "2026_binder.pdf" })
        XCTAssertNotNil(heldOver.uploadedAt)
        XCTAssertNil(heldOver.lastError, "A delivered binder carries no stale error")
        XCTAssertEqual(heldOver.attempts, 2, "Failed once, then delivered")
    }

    /// One binder failing does not hold back the next, and the record says which one
    /// is outstanding. The next build sends that one and leaves the delivered one alone:
    /// nothing already published is sent again.
    func testOnlyTheBinderThatFailedIsRetried() async throws {
        await destination.fail(["2026_spec.pdf"])
        try commit(["march.abc": Self.abc,
                    "binders.yaml": binders(output: "2026_binder.pdf", "2026_spec.pdf")])
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        var log = try await latestBuild().log ?? ""
        XCTAssertTrue(log.contains("[publish] Uploaded 2026_binder.pdf to Stub"), log)
        XCTAssertTrue(log.contains("[publish] ✗ Upload failed for 2026_spec.pdf"), log)
        let pendingAfterFirst = try await outstanding()
        XCTAssertEqual(pendingAfterFirst.map(\.filename), ["2026_spec.pdf"])

        await destination.fail([])
        await destination.resetPublished()
        try commit(["binders.yaml": binders(output: "2026_parade.pdf")], message: "rename")
        await service.runBuild(branch: branch, commitSha: nil, db: app.db, logger: app.logger)

        log = try await latestBuild().log ?? ""
        XCTAssertTrue(log.contains("1 binder(s) held over from an earlier build"), log)
        let published = await destination.published
        XCTAssertEqual(published, ["2026_parade.pdf", "2026_spec.pdf"],
                       "The delivered 2026_binder.pdf is not sent a second time")
        let pending = try await outstanding()
        XCTAssertEqual(pending.map(\.filename), [])
    }

    /// A catalogue sync publishes nothing, even with a destination that would accept it.
    func testACatalogueSyncPublishesNothing() async throws {
        await destination.fail([])
        try commit(["march.abc": Self.abc, "binders.yaml": binders(output: "2026_binder.pdf")])

        await service.syncCatalogue(branch: branch, db: app.db, logger: app.logger)

        let log = try await latestBuild().log ?? ""
        XCTAssertTrue(log.contains("Publishing and Slack notification skipped"), log)
        let published = await destination.published
        XCTAssertEqual(published, [])
    }

    // MARK: - Fixtures

    private static let abc = Data("""
    %abc-2.2
    %%footer "$P"
    X:1
    T:Test March
    M:4/4
    L:1/8
    K:D
    ABcd efga | gfed cBAG |]
    """.utf8)

    private func binders(output: String...) -> Data {
        Data(("binders:\n" + output.map { name in """
              - name: "Band Binder \(name)"
                output: \(name)
                sections:
                  - title: "Grade 4 Tunes"
                    entries:
                      - tune: march

            """ }.joined()).utf8)
    }

    // MARK: - Helpers

    private func outstanding() async throws -> [BinderUpload] {
        try await BinderUpload.outstanding(for: branch, on: app.db)
    }

    private func latestBuild() async throws -> Build {
        let builds = try await Build.query(on: app.db).sort(\.$triggered, .descending).all()
        return try XCTUnwrap(builds.first)
    }

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
}
