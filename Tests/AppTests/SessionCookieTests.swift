import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// The session cookie is `HttpOnly` everywhere, `Secure` wherever `DOMAIN` names a real
/// host, and still `SameSite=Lax` (#94).
final class SessionCookieTests: XCTestCase {

    var app: Application!

    override func tearDown() async throws {
        try await app?.asyncShutdown()
        app = nil
        unsetenv("DOMAIN")
    }

    // MARK: - The cookie a sign-in sets

    func testSigningInSetsAnHttpOnlyLaxCookie() async throws {
        let cookie = try await signInCookie(domain: nil)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.sameSite, .lax)
    }

    func testTheCookieIsSecureUnderARealDomain() async throws {
        let cookie = try await signInCookie(domain: "tng.example.org")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.sameSite, .lax)
    }

    func testTheCookieIsNotSecureWithoutADomain() async throws {
        let cookie = try await signInCookie(domain: nil)
        XCTAssertFalse(cookie.isSecure)
    }

    func testTheCookieIsNotSecureUnderLocalhost() async throws {
        let cookie = try await signInCookie(domain: "localhost:8080")
        XCTAssertFalse(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
    }

    /// The raw header, as a browser reads it, carries the flags.
    func testTheSetCookieHeaderNamesTheFlags() async throws {
        setenv("DOMAIN", "tng.example.org", 1)
        try await makeApp()
        let token = try await loginToken(role: .member)
        try await app.test(.GET, "auth/token/\(token)") { res async in
            let header = res.headers[.setCookie].joined(separator: "\n")
            XCTAssertTrue(header.contains("HttpOnly"), header)
            XCTAssertTrue(header.contains("Secure"), header)
            XCTAssertTrue(header.contains("SameSite=Lax"), header)
        }
    }

    // MARK: - The rule

    func testARealDomainIsSecure() {
        XCTAssertTrue(SessionCookie.isSecure(domain: "tng.example.org"))
        XCTAssertTrue(SessionCookie.isSecure(domain: "musictools.siliconvalleypipeband.com"))
        XCTAssertTrue(SessionCookie.isSecure(domain: " tng.example.org "))
        XCTAssertTrue(SessionCookie.isSecure(domain: "tng.example.org:8443"))
        XCTAssertTrue(SessionCookie.isSecure(domain: "localhost.example.org"))
    }

    func testThisMachineIsNotSecure() {
        for domain in [
            nil, "", "   ",
            "localhost", "localhost:8080", "LocalHost:8080",
            "127.0.0.1", "127.0.0.1:8181",
            "::1", "[::1]", "[::1]:8080",
        ] {
            XCTAssertFalse(SessionCookie.isSecure(domain: domain), String(describing: domain))
        }
    }

    // MARK: - Helpers

    private func makeApp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    private func loginToken(role: UserRole) async throws -> String {
        let slackId = role == .admin ? "U_ADMIN" : "U_MEMBER"
        try await User(slackUserId: slackId, displayName: "User", role: role).save(on: app.db)
        let token = LoginToken(slackUserId: slackId, expiresAt: Date().addingTimeInterval(600))
        try await token.save(on: app.db)
        return try token.requireID().uuidString
    }

    /// Configures the app with `DOMAIN` set to `domain` (or unset), redeems a login link,
    /// and returns the session cookie the response sets.
    private func signInCookie(
        domain: String?, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> HTTPCookies.Value {
        if let domain { setenv("DOMAIN", domain, 1) } else { unsetenv("DOMAIN") }
        try await makeApp()
        let token = try await loginToken(role: .member)

        var cookie: HTTPCookies.Value?
        try await app.test(.GET, "auth/token/\(token)") { res async in
            XCTAssertEqual(res.status, .seeOther, file: file, line: line)
            cookie = res.headers.setCookie?[SessionCookie.name]
        }
        return try XCTUnwrap(cookie, "no session cookie", file: file, line: line)
    }
}
