import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// O6: a binder that could not reach Box is retained locally and sent on the next build.
///
/// The builds here run with no usable Box credentials, which is exactly the shape of the
/// failure being tested — every upload fails before a request is made, so the tests are
/// offline and the retry path is driven by the same code that a Box outage would drive.
/// What is asserted is the record: which binders are outstanding, and what the next build
/// does about them.
final class BoxRetryTests: XCTestCase {

    var app: Application!
    var workspace: URL!
    var origin: URL!
    var service: BuildService!

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
        // and can only reach Box through the retry pass.
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
    /// describes: uploading those bytes under this row would put the wrong version in Box.
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

        let rows = try await BoxUpload.query(on: app.db).all()
        XCTAssertEqual(rows.count, 1, "One row per binder per branch, carried across builds")
        let row = try XCTUnwrap(rows.first)
        XCTAssertNil(row.uploadedAt)
        XCTAssertEqual(row.attempts, 1, "Reset by the rebuild, then bumped by this build's attempt")
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

    private func binders(output: String) -> Data {
        Data("""
        binders:
          - name: "Band Binder"
            output: \(output)
            sections:
              - title: "Grade 4 Tunes"
                entries:
                  - tune: march
        """.utf8)
    }

    // MARK: - Helpers

    private func outstanding() async throws -> [BoxUpload] {
        try await BoxUpload.outstanding(for: branch, on: app.db)
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
