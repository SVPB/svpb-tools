import Foundation
import XCTVapor
import XCTest
@testable import App

/// The admin connections page, and the Box authorisation it can drive.
///
/// The probes themselves reach out to Box, Slack and GitHub, so what is covered here is
/// everything around them: that a service with no credentials reports itself rather than
/// hanging or throwing, that the page is closed to anyone but an admin, and that the
/// authorisation callback refuses anything it did not start.
final class ConnectionsTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        unsetenv("DOMAIN")
    }

    // MARK: - The report

    /// A deployment with nothing configured gets a page that says so, service by service,
    /// rather than an error — this page is most useful precisely when nothing works.
    func testEveryServiceReportsItselfWithoutCredentials() async throws {
        let connections = await ConnectionsReport.gather(on: app)

        XCTAssertEqual(connections.map(\.id), ["github", "box", "slack"],
                       "In the order they matter to a build")
        for connection in connections {
            XCTAssertNotEqual(connection.state, .working,
                              "\(connection.name) cannot be working with no credentials")
            XCTAssertFalse(connection.purpose.isEmpty, "\(connection.name) says what it is for")
            XCTAssertNotNil(connection.error, "\(connection.name) says what is wrong")
        }
    }

    /// Box is the one service that can be re-authorised from the browser; the others are
    /// static configuration and say what to edit instead.
    func testOnlyBoxOffersAnAuthorizeButton() async throws {
        setenv("BOX_CLIENT_ID", "test-client", 1)
        setenv("BOX_CLIENT_SECRET", "test-secret", 1)
        defer { unsetenv("BOX_CLIENT_ID"); unsetenv("BOX_CLIENT_SECRET") }

        let connections = await ConnectionsReport.gather(on: app)

        let withButton = connections.filter { $0.authorizePath != nil }
        XCTAssertEqual(withButton.map(\.id), ["box"])
        for connection in connections where connection.authorizePath == nil {
            XCTAssertNotNil(connection.remedy,
                            "\(connection.name) has no button, so it must say what to do by hand")
        }
    }

    /// Without a client ID and secret there is nothing to authorise *with* — Box needs
    /// them to show a consent screen at all — so the button is withheld and the page says
    /// what is missing instead of offering an action that cannot work.
    func testBoxOffersNoButtonUntilItHasClientCredentials() async throws {
        let connections = await ConnectionsReport.gather(on: app)

        let box = try XCTUnwrap(connections.first { $0.id == "box" })
        XCTAssertEqual(box.state, .unconfigured)
        XCTAssertNil(box.authorizePath)
        XCTAssertNotNil(box.remedy)
        XCTAssertEqual(box.credential, "No refresh token — TNG has never been authorised")
    }

    // MARK: - The redirect URI

    /// Box matches the redirect URI at both ends of the flow, so it has to come out the
    /// same each time — and in production it is the domain Caddy serves, not the host
    /// header of whatever reached the container.
    func testRedirectURIPrefersTheConfiguredDomain() throws {
        setenv("DOMAIN", "tng.siliconvalleypipeband.org", 1)
        let request = Request(application: app, on: app.eventLoopGroup.next())
        request.headers.replaceOrAdd(name: .host, value: "tng:8080")

        XCTAssertEqual(ConnectionsController.redirectURI(for: request),
                       "https://tng.siliconvalleypipeband.org/box-callback")
    }

    /// Local development has no DOMAIN and no TLS, and the tunnel or localhost is the
    /// whole story.
    func testRedirectURIFallsBackToTheRequestHost() throws {
        unsetenv("DOMAIN")
        let request = Request(application: app, on: app.eventLoopGroup.next())
        request.headers.replaceOrAdd(name: .host, value: "localhost:8080")

        XCTAssertEqual(ConnectionsController.redirectURI(for: request),
                       "http://localhost:8080/box-callback")
    }

    // MARK: - The authorisation URL

    func testAuthorizationURLCarriesEverythingBoxNeeds() throws {
        let url = BoxService.authorizationURL(
            clientID: "abc123",
            redirectURI: "https://tng.example.org/box-callback",
            state: "STATE")

        let components = try XCTUnwrap(URLComponents(string: url))
        XCTAssertEqual(components.host, "account.box.com")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["client_id"], "abc123")
        XCTAssertEqual(items["redirect_uri"], "https://tng.example.org/box-callback")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["state"], "STATE")
    }

    /// An authorisation code or a client secret carrying a `+`, `/` or `=` would arrive at
    /// Box as a different string if it were interpolated into the body.
    func testFormEncodingEscapesReservedCharacters() {
        let body = BoxService.formEncoded([
            ("grant_type", "authorization_code"),
            ("code", "a+b/c=d&e"),
        ])

        XCTAssertEqual(body, "grant_type=authorization_code&code=a%2Bb%2Fc%3Dd%26e")
    }

    // MARK: - Access

    func testConnectionsPageIsAdminOnly() async throws {
        try await app.test(.GET, "/admin/connections") { response async in
            XCTAssertEqual(response.status, .seeOther)
            XCTAssertEqual(response.headers.first(name: .location), "/admin/login")
        }
    }

    func testAuthorizeIsAdminOnly() async throws {
        try await app.test(.GET, "/admin/connections/box/authorize") { response async in
            XCTAssertEqual(response.status, .seeOther)
            XCTAssertEqual(response.headers.first(name: .location), "/admin/login")
        }
    }

    // MARK: - The callback

    /// Without a matching `state` in the session the code is not exchanged: a link handed
    /// to a signed-in admin must not be able to drive a token exchange of someone else's
    /// choosing.
    func testCallbackRefusesACodeItDidNotAskFor() async throws {
        try await app.test(.GET, "/box-callback?code=stolen&state=guessed") { response async in
            XCTAssertEqual(response.status, .ok)
            XCTAssertTrue(response.body.string.contains("did not start here"),
                          response.body.string)
            XCTAssertFalse(response.body.string.contains("Authorised ✓"))
        }
    }

    /// Box reports a refusal by redirecting back with `error` rather than `code`, and the
    /// page has to say so rather than looking like a success with nothing in it.
    func testCallbackReportsARefusalFromBox() async throws {
        try await app.test(.GET, "/box-callback?error=access_denied") { response async in
            XCTAssertEqual(response.status, .ok)
            XCTAssertTrue(response.body.string.contains("Authorisation failed"), response.body.string)
            XCTAssertTrue(response.body.string.contains("access_denied"), response.body.string)
            XCTAssertTrue(response.body.string.contains("still using whatever token it had"),
                          "A failure has to say that nothing changed")
        }
    }

    // MARK: - Rendering

    /// The page itself, rendered from a report of every state it has to draw — the admin
    /// routes are behind a session, so this is what catches a broken template before a
    /// deployment does.
    func testPageRendersEveryConnectionState() async throws {
        struct Context: Encodable {
            let appVersion: String
            let isAdmin: Bool
            let currentUser: String
            let connections: [ConnectionStatus]
            let redirectURI: String
        }
        let connections = [
            ConnectionStatus(
                id: "github", name: "GitHub", purpose: "Where the music comes from.",
                state: .working, detail: "github.com/SVPB/svpb-music — 3 branch(es)",
                credential: "Webhook secret set", error: nil,
                authorizePath: nil, remedy: "Set it in .env."),
            ConnectionStatus(
                id: "box", name: "Box", purpose: "Where binders are published.",
                state: .failing, detail: nil, credential: "No refresh token",
                error: "Box rejected the refresh token", 
                authorizePath: "/admin/connections/box/authorize", remedy: nil),
            ConnectionStatus(
                id: "slack", name: "Slack", purpose: "Login links and notifications.",
                state: .unconfigured, detail: nil, credential: nil,
                error: "SLACK_BOT_TOKEN is not set", authorizePath: nil,
                remedy: "Take a token from the Slack app."),
        ]

        let view = try await app.view.render("admin/connections", Context(
            appVersion: AppVersion.current, isAdmin: true, currentUser: "tester",
            connections: connections, redirectURI: "https://tng.example.org/box-callback"))
        let html = String(buffer: view.data)

        XCTAssertTrue(html.contains("state-working"), html)
        XCTAssertTrue(html.contains("state-failing"))
        XCTAssertTrue(html.contains("state-unconfigured"))
        XCTAssertTrue(html.contains("Authorise Box"),
                      "A failing Box offers the button that fixes it")
        XCTAssertTrue(html.contains("Box rejected the refresh token"))
        XCTAssertTrue(html.contains("https://tng.example.org/box-callback"),
                      "The URI to register with Box is on the page to be copied")
        XCTAssertTrue(html.contains("How to fix this"))
        XCTAssertFalse(html.contains("#if("), "Unrendered Leaf tags left in the output")
    }

    /// A working Box offers re-authorisation rather than authorisation: the wording is the
    /// only thing on the page that says which of the two it is.
    func testWorkingBoxSaysReAuthorise() async throws {
        struct Context: Encodable {
            let appVersion: String
            let isAdmin: Bool
            let currentUser: String
            let connections: [ConnectionStatus]
            let redirectURI: String
        }
        let box = ConnectionStatus(
            id: "box", name: "Box", purpose: "Where binders are published.",
            state: .working, detail: "Uploading into pipe_music",
            credential: "Refresh token last renewed 2 days ago", error: nil,
            authorizePath: "/admin/connections/box/authorize", remedy: nil)

        let view = try await app.view.render("admin/connections", Context(
            appVersion: AppVersion.current, isAdmin: true, currentUser: "tester",
            connections: [box], redirectURI: "https://tng.example.org/box-callback"))
        let html = String(buffer: view.data)

        XCTAssertTrue(html.contains("Re-authorise Box"), html)
        XCTAssertTrue(html.contains("Uploading into pipe_music"))
    }

    // MARK: - Credentials in the open

    /// A clone URL can carry a token as userinfo, and a status page exists to be read by
    /// whoever is standing there.
    func testRepositoryURLIsShownWithoutItsCredentials() {
        let service = GitService(
            repoURL: "https://x-access-token:ghp_secret@github.com/SVPB/svpb-music.git",
            workspaceBase: URL(fileURLWithPath: "/tmp"))

        XCTAssertEqual(service.displayRepoURL, "https://github.com/SVPB/svpb-music.git")
        XCTAssertFalse(service.displayRepoURL.contains("ghp_secret"))
    }

    func testAPlainRepositoryURLIsUnchanged() {
        let service = GitService(repoURL: "https://github.com/SVPB/svpb-music.git",
                                 workspaceBase: URL(fileURLWithPath: "/tmp"))

        XCTAssertEqual(service.displayRepoURL, "https://github.com/SVPB/svpb-music.git")
    }
}
