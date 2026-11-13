import Foundation
import XCTVapor
import XCTest
@testable import App

/// `ARTIFACT_DESTINATION` names the one destination a server publishes to, and startup
/// checks only the variables that destination needs (#87).
final class DestinationChoiceTests: XCTestCase {

    /// Everything a Box deployment sets, so each test can take one thing away.
    private let boxDeployment: [String: String] = [
        "GITHUB_WEBHOOK_SECRET": "secret",
        "ORG_MUSIC_REPO_URL": "https://github.com/SVPB/svpb-music.git",
        "SLACK_BOT_TOKEN": "xoxb-test",
        "SLACK_SIGNING_SECRET": "signing",
        "SLACK_WEBHOOK_URL": "https://hooks.slack.com/test",
        "INITIAL_ADMIN_SLACK_USER_ID": "U012AB3CD",
        "BOX_CLIENT_ID": "client",
        "BOX_CLIENT_SECRET": "client-secret",
        "BOX_FOLDER_ID": "12345",
    ]

    private func validate(_ env: [String: String]) throws -> DestinationKind {
        try validateEnvironment { env[$0] }
    }

    // MARK: - Which destination

    /// The running deployment has no `ARTIFACT_DESTINATION`, and must keep publishing to Box.
    func testUnsetMeansBox() throws {
        XCTAssertEqual(try validate(boxDeployment), .box)
    }

    func testBlankMeansBox() throws {
        var env = boxDeployment
        env["ARTIFACT_DESTINATION"] = "  "
        XCTAssertEqual(try validate(env), .box)
    }

    func testBoxByName() throws {
        var env = boxDeployment
        env["ARTIFACT_DESTINATION"] = "box"
        XCTAssertEqual(try validate(env), .box)
    }

    /// A typo must not quietly publish somewhere else, or nowhere: it stops startup, and
    /// the message says what would have been accepted.
    func testAnUnrecognisedValueStopsStartupAndListsTheAcceptedOnes() {
        var env = boxDeployment
        env["ARTIFACT_DESTINATION"] = "dropbox"

        XCTAssertThrowsError(try validate(env)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("'dropbox'"), message)
            XCTAssertTrue(message.contains("Accepted values: box"), message)
        }
    }

    /// The destination is read even where the required variables are not checked, so a
    /// bad value is caught in the test environment as well.
    func testAnUnrecognisedValueIsRefusedWithoutTheRequiredCheck() {
        XCTAssertThrowsError(try validateEnvironment(
            { $0 == "ARTIFACT_DESTINATION" ? "s3" : nil }, checkRequired: false))
    }

    // MARK: - Which variables

    func testBoxNeedsItsOwnCredentials() {
        for key in ["BOX_CLIENT_ID", "BOX_CLIENT_SECRET", "BOX_FOLDER_ID"] {
            var env = boxDeployment
            env[key] = nil
            XCTAssertThrowsError(try validate(env), "\(key) is required for Box") { error in
                XCTAssertTrue("\(error)".contains(key), "\(error)")
            }
        }
    }

    /// Box obtains its refresh token from the connections page, which the server has to
    /// start to serve.
    func testBoxStartsWithoutARefreshToken() throws {
        XCTAssertNil(boxDeployment["BOX_REFRESH_TOKEN"])
        XCTAssertEqual(try validate(boxDeployment), .box)
    }

    func testTheCommonVariablesAreRequiredWhateverTheDestination() {
        for key in ["GITHUB_WEBHOOK_SECRET", "ORG_MUSIC_REPO_URL", "SLACK_BOT_TOKEN",
                    "SLACK_SIGNING_SECRET", "SLACK_WEBHOOK_URL", "INITIAL_ADMIN_SLACK_USER_ID"] {
            var env = boxDeployment
            env[key] = nil
            XCTAssertThrowsError(try validate(env), "\(key) is required")
        }
    }

    /// The production `.env` still says `SVPB_MUSIC_REPO_URL`, and must keep starting the
    /// server on the day #89 deploys.
    func testTheMusicRepositorysOldNameSatisfiesTheCheck() throws {
        var env = boxDeployment
        env["ORG_MUSIC_REPO_URL"] = nil
        env["SVPB_MUSIC_REPO_URL"] = "https://github.com/SVPB/svpb-music.git"
        XCTAssertEqual(try validate(env), .box)
    }

    /// A missing repository is reported by its new name.
    func testAMissingMusicRepositoryIsReportedByItsNewName() {
        var env = boxDeployment
        env["ORG_MUSIC_REPO_URL"] = nil
        XCTAssertThrowsError(try validate(env)) { error in
            XCTAssertTrue("\(error)".contains("ORG_MUSIC_REPO_URL"), "\(error)")
        }
    }

    /// Each destination asks only for its own variables; none asks for another's.
    func testNoDestinationRequiresAnotherDestinationsVariables() {
        for kind in DestinationKind.allCases {
            let prefix = kind.rawValue.uppercased() + "_"
            for key in kind.requiredEnvironmentVariables {
                XCTAssertTrue(key.hasPrefix(prefix), "\(kind) requires \(key)")
            }
        }
    }

    // MARK: - What gets built

    func testConfigureRefusesAnUnrecognisedDestination() async throws {
        setenv("ARTIFACT_DESTINATION", "dropbox", 1)
        defer { unsetenv("ARTIFACT_DESTINATION") }

        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            XCTFail("configure accepted an unrecognised destination")
        } catch {
            XCTAssertTrue("\(error)".contains("Accepted values"), "\(error)")
        }
        try await app.asyncShutdown()
    }

    func testConfigureBuildsTheChosenDestination() async throws {
        setenv("ARTIFACT_DESTINATION", "box", 1)
        defer { unsetenv("ARTIFACT_DESTINATION") }

        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            XCTAssertTrue(app.artifactDestination is BoxService)
        } catch {
            XCTFail("\(error)")
        }
        try await app.asyncShutdown()
    }

    /// The connections page has one destination card: the active destination's.
    func testTheConnectionsPageShowsOnlyTheActiveDestination() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)

            let withBox = await ConnectionsReport.gather(on: app).map(\.id)
            XCTAssertEqual(withBox, ["github", "box", "slack", "backup"])

            app.artifactDestination = StubDestination()
            let withStub = await ConnectionsReport.gather(on: app).map(\.id)
            XCTAssertEqual(withStub, ["github", "stub", "slack", "backup"],
                           "Box is not asked about once it is not the destination")
        } catch {
            XCTFail("\(error)")
        }
        try await app.asyncShutdown()
    }
}
