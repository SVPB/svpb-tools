import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// A request that signs nobody in leaves nothing behind in `_fluent_sessions` (#92).
final class SessionCreationTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    private let cookieName = "vapor-session"

    // MARK: - No cookie

    func testPagesThatAskWhoIsSignedInCreateNoSession() async throws {
        for path in ["/", "/binder-constructor", "/binder-builder", "/admin", "/admin/connections"] {
            try await app.test(.GET, path) { res async in
                XCTAssertNotEqual(res.status, .internalServerError, path)
                XCTAssertNil(res.headers.setCookie?[self.cookieName], "\(path) set a session cookie")
            }
        }
        try await assertSessionCount(0)
    }

    func testManyCookielessRequestsLeaveTheTableEmpty() async throws {
        for _ in 1...100 {
            try await app.test(.GET, "/") { _ async in }
        }
        try await assertSessionCount(0)
    }

    /// The Box callback reads the session to check its state, signed in or not.
    func testBoxCallbackWithoutASessionCreatesNone() async throws {
        try await app.test(.GET, "/box-callback?code=stolen&state=guessed") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertNil(res.headers.setCookie?[self.cookieName])
        }
        try await assertSessionCount(0)
    }

    // MARK: - Unknown cookie

    /// Vapor installs an empty session for a cookie naming no stored one, before any route
    /// runs — so this holds even where the route never reads the session.
    func testAnUnknownCookieCreatesNoSessionAndIsExpired() async throws {
        for path in ["/", "/health"] {
            try await app.test(.GET, path, beforeRequest: { req async in
                req.headers.cookie = [self.cookieName: .init(string: "made-up-\(path)")]
            }, afterResponse: { res async in
                let cookie = res.headers.setCookie?[self.cookieName]
                XCTAssertNotNil(cookie, "\(path) should expire the unknown cookie")
                XCTAssertEqual(cookie?.string, "", path)
                XCTAssertLessThan(cookie?.expires ?? .distantFuture, Date(), path)
            })
        }
        try await assertSessionCount(0)
    }

    func testAnExistingEmptySessionIsDeletedWhenItsCookieIsUsed() async throws {
        let key = SessionID(string: "left-behind")
        try await SessionRecord(key: key, data: SessionData()).save(on: app.db)
        try await assertSessionCount(1)

        try await app.test(.GET, "/", beforeRequest: { req async in
            req.headers.cookie = [self.cookieName: .init(string: key.string)]
        }, afterResponse: { res async in
            XCTAssertEqual(res.headers.setCookie?[self.cookieName]?.string, "")
        })
        try await assertSessionCount(0)
    }

    // MARK: - Sessions that are kept

    func testSigningInCreatesExactlyOneSessionThatLasts() async throws {
        let cookies = try await signInAsAdmin()
        try await assertSessionCount(1)

        try await app.test(.GET, "/admin", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
        try await assertSessionCount(1)
    }

    /// The authorisation's state is written into the admin's session on the way to Box
    /// and must still be there when Box sends the browser back.
    func testBoxAuthorisationStateSurvivesTheRoundTrip() async throws {
        let cookies = try await signInAsAdmin()

        var state: String?
        try await app.test(.GET, "/admin/connections/destination/authorize", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .seeOther)
            let location = res.headers.first(name: .location) ?? ""
            state = URLComponents(string: location)?.queryItems?.first { $0.name == "state" }?.value
        })
        let sent = try XCTUnwrap(state)

        // No `code`, so nothing is exchanged: getting past the state check is the proof.
        try await app.test(.GET, "/box-callback?state=\(sent)", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertFalse(res.body.string.contains("did not start here"), res.body.string)
            XCTAssertTrue(res.body.string.contains("Box sent no authorisation code."), res.body.string)
        })
        try await assertSessionCount(1)
    }

    // MARK: - Helpers

    private func assertSessionCount(
        _ expected: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let count = try await SessionRecord.query(on: app.db).count()
        XCTAssertEqual(count, expected, "rows in _fluent_sessions", file: file, line: line)
    }

    /// Signs in as an admin by redeeming a magic link, and returns the session cookie.
    private func signInAsAdmin() async throws -> HTTPCookies {
        try await User(slackUserId: "U_ADMIN", displayName: "Admin", role: .admin).save(on: app.db)
        let token = LoginToken(slackUserId: "U_ADMIN", expiresAt: Date().addingTimeInterval(600))
        try await token.save(on: app.db)

        var cookies: HTTPCookies = [:]
        try await app.test(.GET, "auth/token/\(token.id!.uuidString)") { res async in
            XCTAssertEqual(res.status, .seeOther)
            cookies = res.headers.setCookie ?? [:]
        }
        return cookies
    }
}
