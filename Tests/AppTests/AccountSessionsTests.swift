import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// A signed-in user sees the browsers they are signed in on and can end any of them, and
/// an admin can end anyone's (#90).
final class AccountSessionsTests: XCTestCase {

    var app: Application!

    private let cookieName = SessionCookie.name
    private let safariOnIPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private let firefoxOnMac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.5; rv:131.0) Gecko/20100101 Firefox/131.0"

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    // MARK: - Sign-in

    func testSignInRecordsTheUserAgent() async throws {
        let member = try await makeUser("U_MEMBER", role: .member)
        _ = try await signIn(member, userAgent: safariOnIPhone)

        let rows = try await SessionRecord.query(on: app.db).all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.data[UserSessions.userAgentKey], safariOnIPhone)
    }

    // MARK: - The page

    func testAccountListsOnlyTheUsersSessionsAndMarksThisBrowser() async throws {
        let member = try await makeUser("U_MEMBER", role: .member)
        let other = try await makeUser("U_OTHER", role: .member)
        let phone = try await signIn(member, userAgent: safariOnIPhone)
        _ = try await signIn(member, userAgent: firefoxOnMac)
        _ = try await signIn(other, userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0")

        let keys = try await SessionRecord.query(on: app.db).all().map(\.key.string)
        let otherIds = try await UserSessions.records(of: try other.requireID(), on: app.db)
            .map { try $0.requireID().uuidString }

        try await app.test(.GET, "account", beforeRequest: { req async in
            req.headers.cookie = phone
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            let body = res.body.string
            XCTAssertTrue(body.contains("Safari on iPhone"))
            XCTAssertTrue(body.contains("Firefox on Mac"))
            XCTAssertFalse(body.contains("Edge on Windows"), "another user's session")
            for id in otherIds { XCTAssertFalse(body.contains(id)) }
            XCTAssertEqual(body.components(separatedBy: "This browser").count - 1, 1)
            // This browser's row comes first, and it is the phone.
            let mark = body.range(of: "This browser")!
            let firefox = body.range(of: "Firefox on Mac")!
            XCTAssertLessThan(mark.lowerBound, firefox.lowerBound)
            for key in keys {
                XCTAssertFalse(body.contains(key), "a session key is the credential and must never be shown")
            }
        })
    }

    func testAccountRequiresASession() async throws {
        try await app.test(.GET, "account") { res async in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin/login")
        }
    }

    func testAccountWorksForAMemberAndAnAdmin() async throws {
        for (slackId, role) in [("U_MEMBER", UserRole.member), ("U_ADMIN", .admin)] {
            let user = try await makeUser(slackId, role: role)
            let cookies = try await signIn(user)
            try await app.test(.GET, "account", beforeRequest: { req async in
                req.headers.cookie = cookies
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok, "\(role)")
                XCTAssertTrue(res.body.string.contains("This browser"), "\(role)")
            })
        }
    }

    func testSignedInAsLinksToAccount() async throws {
        let cookies = try await signIn(try await makeUser("U_MEMBER", role: .member))
        try await app.test(.GET, "/", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertTrue(res.body.string.contains(#"href="/account""#))
        })
    }

    // MARK: - Ending one

    func testEndingOneSessionLeavesTheOthers() async throws {
        let member = try await makeUser("U_MEMBER", role: .member)
        let phone = try await signIn(member, userAgent: safariOnIPhone)
        let laptop = try await signIn(member, userAgent: firefoxOnMac)
        let laptopId = try await sessionId(of: laptop)

        try await post("account/sessions/\(laptopId)/end", cookies: phone) { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/account")
        }

        try await assertSignedIn(phone)
        try await assertSignedOut(laptop)
    }

    func testEndingThisBrowsersSessionSignsOut() async throws {
        let member = try await makeUser("U_MEMBER", role: .member)
        let phone = try await signIn(member)
        let laptop = try await signIn(member)
        let phoneId = try await sessionId(of: phone)

        try await post("account/sessions/\(phoneId)/end", cookies: phone) { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/")
            XCTAssertEqual(res.headers.setCookie?[self.cookieName]?.string, "", "cookie should be expired")
        }

        try await assertSignedOut(phone)
        try await assertSignedIn(laptop)
    }

    func testEndingAnotherUsersSessionIsRefused() async throws {
        let member = try await makeUser("U_MEMBER", role: .member)
        let other = try await makeUser("U_OTHER", role: .admin)
        let mine = try await signIn(member)
        let theirs = try await signIn(other)
        let theirId = try await sessionId(of: theirs)

        try await post("account/sessions/\(theirId)/end", cookies: mine) { res in
            XCTAssertEqual(res.status, .notFound)
        }
        try await post("account/sessions/\(UUID())/end", cookies: mine) { res in
            XCTAssertEqual(res.status, .notFound)
        }
        try await assertSignedIn(theirs)
        try await assertSignedIn(mine)
    }

    // MARK: - Ending several

    func testSignOutOtherBrowsersKeepsThisOne() async throws {
        let member = try await makeUser("U_MEMBER", role: .member)
        let other = try await makeUser("U_OTHER", role: .member)
        let phone = try await signIn(member)
        let laptop = try await signIn(member)
        let tablet = try await signIn(member)
        let theirs = try await signIn(other)

        try await post("account/sessions/end-others", cookies: phone) { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/account")
        }

        try await assertSignedIn(phone)
        try await assertSignedOut(laptop)
        try await assertSignedOut(tablet)
        try await assertSignedIn(theirs)
    }

    func testSignOutEverywhereEndsThisOneToo() async throws {
        let member = try await makeUser("U_MEMBER", role: .member)
        let other = try await makeUser("U_OTHER", role: .member)
        let phone = try await signIn(member)
        let laptop = try await signIn(member)
        let theirs = try await signIn(other)

        try await post("account/sessions/end-all", cookies: phone) { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/")
            XCTAssertEqual(res.headers.setCookie?[self.cookieName]?.string, "", "cookie should be expired")
        }

        try await assertSignedOut(phone)
        try await assertSignedOut(laptop)
        try await assertSignedIn(theirs)
        let left = try await UserSessions.records(of: try member.requireID(), on: app.db)
        XCTAssertTrue(left.isEmpty)
    }

    func testEndingSessionsRequiresASession() async throws {
        let member = try await makeUser("U_MEMBER", role: .member)
        let cookies = try await signIn(member)
        let id = try await sessionId(of: cookies)

        for path in ["account/sessions/\(id)/end", "account/sessions/end-others", "account/sessions/end-all"] {
            try await app.test(.POST, path) { res async in
                XCTAssertEqual(res.status, .seeOther, path)
                XCTAssertEqual(res.headers.first(name: .location), "/admin/login", path)
            }
        }
        try await assertSignedIn(cookies)
    }

    // MARK: - Admins

    func testAdminEndsAllOfAUsersSessions() async throws {
        let admin = try await makeUser("U_ADMIN", role: .admin)
        let member = try await makeUser("U_MEMBER", role: .member)
        let adminCookies = try await signIn(admin)
        let phone = try await signIn(member)
        let laptop = try await signIn(member)

        try await app.test(.GET, "admin/users", beforeRequest: { req async in
            req.headers.cookie = adminCookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("/admin/users/\(try member.requireID())/sessions/end"))
        })

        try await post("admin/users/\(try member.requireID())/sessions/end", cookies: adminCookies) { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin/users")
        }

        try await assertSignedOut(phone)
        try await assertSignedOut(laptop)
        try await assertSignedIn(adminCookies)
    }

    func testTheUsersPageCountsLiveSessions() async throws {
        let admin = try await makeUser("U_ADMIN", role: .admin)
        let member = try await makeUser("U_MEMBER", role: .member)
        let adminCookies = try await signIn(admin)
        for _ in 0..<3 { _ = try await signIn(member) }

        let counts = try await UserSessions.liveCounts(
            on: app.db, now: Date(), policy: app.sessionExpiryPolicy)
        XCTAssertEqual(counts[try member.requireID()], 3)
        XCTAssertEqual(counts[try admin.requireID()], 1)

        try await app.test(.GET, "admin/users", beforeRequest: { req async in
            req.headers.cookie = adminCookies
        }, afterResponse: { res async in
            XCTAssertTrue(res.body.string.contains("<th>Sessions</th>"))
        })
    }

    func testEndingAUsersSessionsRequiresAnAdmin() async throws {
        let member = try await makeUser("U_MEMBER", role: .member)
        let victim = try await makeUser("U_OTHER", role: .member)
        let memberCookies = try await signIn(member)
        let victimCookies = try await signIn(victim)

        try await post("admin/users/\(try victim.requireID())/sessions/end", cookies: memberCookies) { res in
            XCTAssertEqual(res.status, .forbidden)
        }
        try await app.test(.POST, "admin/users/\(try victim.requireID())/sessions/end") { res async in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin/login")
        }
        try await assertSignedIn(victimCookies)
    }

    func testDeletingAUserEndsTheirSessions() async throws {
        let admin = try await makeUser("U_ADMIN", role: .admin)
        let member = try await makeUser("U_MEMBER", role: .member)
        let adminCookies = try await signIn(admin)
        _ = try await signIn(member)
        _ = try await signIn(member)

        try await app.test(.DELETE, "admin/users/\(try member.requireID())", beforeRequest: { req async in
            req.headers.cookie = adminCookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .noContent)
        })

        let rows = try await SessionRecord.query(on: app.db).all()
        XCTAssertEqual(rows.count, 1, "only the admin's own session is left")
        XCTAssertEqual(rows.first?.data["userId"], try admin.requireID().uuidString)
    }

    // MARK: - Naming the browser

    func testDeviceLabels() {
        let cases: [(String?, String)] = [
            (safariOnIPhone, "Safari on iPhone"),
            (firefoxOnMac, "Firefox on Mac"),
            ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", "Safari on Mac"),
            ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", "Chrome on Windows"),
            ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0", "Edge on Windows"),
            ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36", "Chrome on Android"),
            ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0.6723.90 Mobile/15E148 Safari/604.1", "Chrome on iPhone"),
            ("Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", "Safari on iPad"),
            ("Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0", "Firefox on Linux"),
            ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 OPR/114.0.0.0", "Opera on Linux"),
            ("Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", "Chrome on ChromeOS"),
            ("curl/8.7.1", "Unknown browser"),
            ("SomeBrowser/1.0 (Windows NT 10.0)", "A browser on Windows"),
            ("", "Unknown browser"),
            (nil, "Unknown browser"),
        ]
        for (ua, expected) in cases {
            XCTAssertEqual(UserSessions.deviceLabel(userAgent: ua), expected, ua ?? "nil")
        }
    }

    func testAnOverlongUserAgentIsCut() {
        let long = String(repeating: "x", count: 5_000)
        XCTAssertEqual(UserSessions.storedUserAgent(long)?.count, UserSessions.maxUserAgentLength)
        XCTAssertNil(UserSessions.storedUserAgent("  "))
    }

    // MARK: - Helpers

    private func makeUser(_ slackId: String, role: UserRole) async throws -> User {
        let user = User(slackUserId: slackId, displayName: slackId, role: role)
        try await user.save(on: app.db)
        return user
    }

    /// Redeems a fresh login link for `user` in a new browser and returns its cookies.
    private func signIn(_ user: User, userAgent: String? = nil) async throws -> HTTPCookies {
        let token = LoginToken(slackUserId: user.slackUserId, expiresAt: Date().addingTimeInterval(600))
        try await token.save(on: app.db)
        var cookies: HTTPCookies = [:]
        try await app.test(.GET, "auth/token/\(try token.requireID())", beforeRequest: { req async in
            if let userAgent { req.headers.replaceOrAdd(name: .userAgent, value: userAgent) }
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .seeOther)
            cookies = res.headers.setCookie ?? [:]
        })
        return cookies
    }

    /// The row id of the session `cookies` carry.
    private func sessionId(of cookies: HTTPCookies) async throws -> UUID {
        let key = try XCTUnwrap(cookies[cookieName]?.string)
        let record = try await SessionRecord.query(on: app.db)
            .filter(\.$key == SessionID(string: key)).first()
        return try XCTUnwrap(record?.requireID())
    }

    private func post(
        _ path: String, cookies: HTTPCookies, _ check: @escaping (XCTHTTPResponse) throws -> Void
    ) async throws {
        try await app.test(.POST, path, beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async throws in
            try check(res)
        })
    }

    private func assertSignedIn(
        _ cookies: HTTPCookies, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await app.test(.GET, "account", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok, "expected to be signed in", file: file, line: line)
        })
    }

    private func assertSignedOut(
        _ cookies: HTTPCookies, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await app.test(.GET, "account", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .seeOther, "expected to be signed out", file: file, line: line)
        })
    }
}
