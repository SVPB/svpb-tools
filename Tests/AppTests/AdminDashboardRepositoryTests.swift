import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// The dashboard says which music repository the branches below it came from.
///
/// The server has pointed at a development repository while looking exactly like one pointed
/// at the band's, so the answer belongs on the page that lists the branches — as text, never
/// as a control: nothing here changes where the server reads from.
final class AdminDashboardRepositoryTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testTheDashboardNamesTheConfiguredRepository() async throws {
        app.gitService = GitService(
            repoURL: "https://github.com/SVPB/svpb-music.git",
            workspaceBase: URL(fileURLWithPath: NSTemporaryDirectory()))

        let html = try await dashboardHTML()

        XCTAssertTrue(html.contains("Music repository:"), html)
        XCTAssertTrue(html.contains("https://github.com/SVPB/svpb-music.git"), html)
    }

    /// A clone URL can carry a token, and a rendered page is where a secret stops being one.
    func testTheDashboardStripsCredentialsFromTheRepositoryURL() async throws {
        app.gitService = GitService(
            repoURL: "https://x-access-token:ghp_secret@github.com/SVPB/svpb-music.git",
            workspaceBase: URL(fileURLWithPath: NSTemporaryDirectory()))

        let html = try await dashboardHTML()

        XCTAssertFalse(html.contains("ghp_secret"), html)
        XCTAssertTrue(html.contains("https://github.com/SVPB/svpb-music.git"), html)
    }

    /// An unconfigured repository is itself the interesting fact — it must not render as a gap.
    func testTheDashboardSaysSoWhenNoRepositoryIsConfigured() async throws {
        app.gitService = GitService(
            repoURL: "",
            workspaceBase: URL(fileURLWithPath: NSTemporaryDirectory()))

        let html = try await dashboardHTML()

        XCTAssertTrue(html.contains("not configured"), html)
    }

    // MARK: - Helpers

    /// Signs in as an admin the way a real admin does — by redeeming a magic link — and
    /// returns the rendered dashboard.
    private func dashboardHTML() async throws -> String {
        let user = User(slackUserId: "U_ADMIN", displayName: "Admin", role: .admin)
        try await user.save(on: app.db)
        let token = LoginToken(slackUserId: "U_ADMIN", expiresAt: Date().addingTimeInterval(600))
        try await token.save(on: app.db)

        var cookies: HTTPCookies = [:]
        try await app.test(.GET, "auth/token/\(token.id!.uuidString)") { res async in
            XCTAssertEqual(res.status, .seeOther)
            cookies = res.headers.setCookie ?? [:]
        }

        var html = ""
        try await app.test(.GET, "admin", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok, "Expected the dashboard, not a redirect to login")
            html = res.body.string
        })
        return html
    }
}
