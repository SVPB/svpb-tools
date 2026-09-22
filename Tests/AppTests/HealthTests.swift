import Foundation
import XCTest
import XCTVapor
@testable import App

final class HealthTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testGetHealthReturnsOK() async throws {
        try await app.test(.GET, "health") { res async in
            XCTAssertEqual(res.status, .ok)
        }
    }

    func testGetHealthBodyShape() async throws {
        try await app.test(.GET, "health") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(HealthResponse.self)
            XCTAssertEqual(body.status, .ok)
            XCTAssertEqual(body.version, AppVersion.current)
            XCTAssertEqual(body.commit, AppVersion.commit)
            XCTAssertTrue(body.branches.isEmpty)
            XCTAssertNil(body.lastBuild)
        }
    }

    func testGetHealthContentTypeIsJSON() async throws {
        try await app.test(.GET, "health") { res async in
            XCTAssertEqual(res.headers.contentType, .json)
        }
    }

    // MARK: - Which repository is this server reading?

    /// `/health` needs no login, which is the point: the question "is this server pointed at
    /// the band's repository or a development one?" can be answered without finding one.
    func testGetHealthNamesTheConfiguredMusicRepository() async throws {
        app.gitService = GitService(
            repoURL: "https://github.com/SVPB/svpb-music.git",
            workspaceBase: URL(fileURLWithPath: NSTemporaryDirectory()))

        try await app.test(.GET, "health") { res async throws in
            let body = try res.content.decode(HealthResponse.self)
            XCTAssertEqual(body.musicRepo, "https://github.com/SVPB/svpb-music.git")
        }
    }

    /// Unauthenticated means a clone token in the URL would be handed to anyone who asked.
    func testGetHealthNeverRepeatsACredentialFromTheRepositoryURL() async throws {
        app.gitService = GitService(
            repoURL: "https://x-access-token:ghp_secret@github.com/SVPB/svpb-music.git",
            workspaceBase: URL(fileURLWithPath: NSTemporaryDirectory()))

        try await app.test(.GET, "health") { res async throws in
            let body = try res.content.decode(HealthResponse.self)
            XCTAssertEqual(body.musicRepo, "https://github.com/SVPB/svpb-music.git")
            XCTAssertFalse(res.body.string.contains("ghp_secret"), res.body.string)
        }
    }

    func testGetHealthOmitsTheRepositoryWhenNoneIsConfigured() async throws {
        app.gitService = GitService(
            repoURL: "",
            workspaceBase: URL(fileURLWithPath: NSTemporaryDirectory()))

        try await app.test(.GET, "health") { res async throws in
            let body = try res.content.decode(HealthResponse.self)
            XCTAssertNil(body.musicRepo)
        }
    }

    // MARK: - Which commit is this server running? (#65)

    func testVersionCarriesTheShortCommitAsBuildMetadata() {
        XCTAssertEqual(
            AppVersion.describe(release: "0.4.0", commit: "a3a6f58c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a"),
            "0.4.0+a3a6f58")
    }

    func testVersionWithoutACommitIsTheBareRelease() {
        XCTAssertEqual(AppVersion.describe(release: "0.4.0", commit: nil), "0.4.0")
    }

    func testCommitIsReadFromTheEnvironment() {
        XCTAssertEqual(AppVersion.commit(from: ["TNG_GIT_COMMIT": "a3a6f58c1d2e\n"]), "a3a6f58c1d2e")
    }

    /// The Dockerfile declares the variable with an empty default, so an image built without
    /// the build arg has it set to "" — which must read as no commit, not as `0.4.0+`.
    func testBlankOrMissingCommitIsNoCommit() {
        XCTAssertNil(AppVersion.commit(from: [:]))
        XCTAssertNil(AppVersion.commit(from: ["TNG_GIT_COMMIT": ""]))
        XCTAssertNil(AppVersion.commit(from: ["TNG_GIT_COMMIT": "  "]))
    }

    func testHealthResponseReportsTheCommitAsItsOwnField() throws {
        let response = HealthResponse(status: .ok, commit: "a3a6f58c1d2e")
        let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertTrue(json.contains(#""commit":"a3a6f58c1d2e""#), json)
    }
}
