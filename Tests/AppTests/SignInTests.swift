import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// A member who redeems a login link stays signed in, and anyone can sign out (#91).
final class SignInTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    // MARK: - Redemption

    func testMemberIsSentHomeAndStaysSignedIn() async throws {
        let (cookies, location) = try await signIn(as: .member)
        XCTAssertEqual(location, "/")

        try await assertSignedIn(cookies, as: "Member")
    }

    func testAdminIsSentToTheDashboard() async throws {
        let (cookies, location) = try await signIn(as: .admin)
        XCTAssertEqual(location, "/admin")

        try await app.test(.GET, "admin", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
        })
    }

    // MARK: - Admin pages

    func testMemberIsRefusedAnAdminPageButStaysSignedIn() async throws {
        let (cookies, _) = try await signIn(as: .member)

        try await app.test(.GET, "admin", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .forbidden)
        })

        try await assertSignedIn(cookies, as: "Member")
    }

    func testSessionOfADeletedUserIsCleared() async throws {
        let (cookies, _) = try await signIn(as: .member)
        try await User.query(on: app.db).filter(\.$slackUserId == "U_MEMBER").delete()

        try await app.test(.GET, "admin", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin/login")
        })

        let sessions = try await SessionRecord.query(on: app.db).count()
        XCTAssertEqual(sessions, 0)
    }

    // MARK: - Sign-out

    func testMemberCanSignOut() async throws {
        try await assertSignOutEndsTheSession(for: .member)
    }

    func testAdminCanSignOut() async throws {
        try await assertSignOutEndsTheSession(for: .admin)
    }

    func testOldAdminSignOutRouteIsGone() async throws {
        let (cookies, _) = try await signIn(as: .admin)

        try await app.test(.POST, "admin/logout", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - Helpers

    /// Redeems a fresh login link for a new user with `role`, and returns the session
    /// cookie and the redirect target.
    private func signIn(as role: UserRole) async throws -> (HTTPCookies, String?) {
        let slackId = role == .admin ? "U_ADMIN" : "U_MEMBER"
        let name = role == .admin ? "Admin" : "Member"
        try await User(slackUserId: slackId, displayName: name, role: role).save(on: app.db)
        let token = LoginToken(slackUserId: slackId, expiresAt: Date().addingTimeInterval(600))
        try await token.save(on: app.db)

        var cookies: HTTPCookies = [:]
        var location: String?
        try await app.test(.GET, "auth/token/\(token.id!.uuidString)") { res async in
            XCTAssertEqual(res.status, .seeOther)
            cookies = res.headers.setCookie ?? [:]
            location = res.headers.first(name: .location)
        }
        return (cookies, location)
    }

    private func assertSignedIn(
        _ cookies: HTTPCookies, as name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await app.test(.GET, "/", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok, file: file, line: line)
            XCTAssertTrue(res.body.string.contains("Signed in as \(name)"), file: file, line: line)
        })
    }

    private func assertSignOutEndsTheSession(
        for role: UserRole, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let (cookies, _) = try await signIn(as: role)

        try await app.test(.POST, "logout", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .seeOther, file: file, line: line)
            XCTAssertEqual(res.headers.first(name: .location), "/", file: file, line: line)
        })
        let sessions = try await SessionRecord.query(on: app.db).count()
        XCTAssertEqual(sessions, 0, file: file, line: line)

        try await app.test(.GET, "/", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertFalse(res.body.string.contains("Signed in as"), file: file, line: line)
        })
    }
}
