import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// A sign-in ends after `SESSION_IDLE_DAYS` unused or `SESSION_MAX_DAYS` in all, and the
/// server, not the browser, enforces it (#93).
final class SessionExpiryTests: XCTestCase {

    var app: Application!
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))

    private let cookieName = "vapor-session"
    private let day: TimeInterval = 24 * 60 * 60
    private let policy = SessionExpiry.Policy.default

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        let clock = self.clock
        app.sessionClock = { clock.now }
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    // MARK: - Idle limit

    func testASessionUsedWithinTheIdleLimitStaysSignedInAndAdvances() async throws {
        let cookies = try await signIn(as: .member)
        let firstSeen = try await storedStamp(SessionExpiry.lastSeenAtKey)

        clock.advance(by: TimeInterval(policy.idleDays) * day - 60)
        try await assertSignedIn(cookies)

        let lastSeen = try await storedStamp(SessionExpiry.lastSeenAtKey)
        XCTAssertEqual(lastSeen, clock.now)
        XCTAssertGreaterThan(lastSeen, firstSeen)
    }

    func testASessionIdleTooLongIsSignedOutAndItsRowIsGone() async throws {
        let cookies = try await signIn(as: .member)

        clock.advance(by: TimeInterval(policy.idleDays) * day)
        try await app.test(.GET, "/", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertFalse(res.body.string.contains("Signed in as"))
            XCTAssertEqual(res.headers.setCookie?[self.cookieName]?.string, "", "cookie should be expired")
        })
        try await assertSessionCount(0)
    }

    // MARK: - Absolute limit

    func testASessionInDailyUseIsSignedOutAfterTheMaximum() async throws {
        let cookies = try await signIn(as: .member)

        for _ in 1..<policy.maxDays {
            clock.advance(by: day)
            try await assertSignedIn(cookies)
        }
        clock.advance(by: day)
        try await assertSignedOut(cookies)
        try await assertSessionCount(0)
    }

    // MARK: - Admin pages

    func testAnExpiredSessionIsSentToTheAdminLoginPage() async throws {
        let cookies = try await signIn(as: .admin)

        clock.advance(by: TimeInterval(policy.idleDays) * day + 1)
        try await app.test(.GET, "admin", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin/login")
        })
        try await assertSessionCount(0)
    }

    // MARK: - Signing in again

    /// The expired session is emptied, not destroyed, so the new sign-in fills it.
    func testRedeemingALinkFromABrowserWithAnExpiredSessionSignsIn() async throws {
        let old = try await signIn(as: .member)
        clock.advance(by: TimeInterval(policy.maxDays) * day)

        let token = try await loginToken(for: "U_MEMBER")
        var cookies: HTTPCookies = [:]
        try await app.test(.GET, "auth/token/\(token)", beforeRequest: { req async in
            req.headers.cookie = old
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .seeOther)
            cookies = res.headers.setCookie ?? [:]
        })
        XCTAssertFalse(cookies[cookieName]?.string.isEmpty ?? true, "sign-in should set a live cookie")

        try await assertSignedIn(cookies)
        try await assertSessionCount(1)
        let signedIn = try await storedStamp(SessionExpiry.signedInAtKey)
        XCTAssertEqual(signedIn, clock.now, "the new sign-in restarts the absolute limit")
    }

    // MARK: - Sessions from before #93

    /// Their limits count from the migration, not from whenever the cookie turns up again.
    func testSessionsFromBefore93AreStampedWithTheMigrationTime() async throws {
        let key = try await saveUnstampedSession()
        let migratedAt = clock.now
        let stamped = try await SessionExpiry.stampUnstampedSessions(on: app.db, now: migratedAt)
        XCTAssertEqual(stamped, 1)
        let signedIn = try await storedStamp(SessionExpiry.signedInAtKey)
        let lastSeen = try await storedStamp(SessionExpiry.lastSeenAtKey)
        XCTAssertEqual(signedIn, migratedAt)
        XCTAssertEqual(lastSeen, migratedAt)

        // Unused since the migration: the idle limit runs out on schedule.
        clock.advance(by: TimeInterval(policy.idleDays) * day)
        try await assertSignedOut([cookieName: .init(string: key.string)])
        try await assertSessionCount(0)
    }

    func testAStampedSessionFromBefore93StaysSignedInWithinTheLimit() async throws {
        let key = try await saveUnstampedSession()
        try await SessionExpiry.stampUnstampedSessions(on: app.db, now: clock.now)

        clock.advance(by: TimeInterval(policy.idleDays) * day - 60)
        try await assertSignedIn([cookieName: .init(string: key.string)])
    }

    func testStampingLeavesStampedSessionsAlone() async throws {
        _ = try await signIn(as: .member)
        let signedIn = try await storedStamp(SessionExpiry.signedInAtKey)

        clock.advance(by: day)
        let stamped = try await SessionExpiry.stampUnstampedSessions(on: app.db, now: clock.now)
        XCTAssertEqual(stamped, 0)
        let after = try await storedStamp(SessionExpiry.signedInAtKey)
        XCTAssertEqual(after, signedIn)
    }

    /// Every sign-in is stamped and the migration stamped the rest, so a session without
    /// stamps is one whose age can't be known.
    func testASignedInSessionWithNoStampsIsSignedOut() async throws {
        let key = try await saveUnstampedSession()
        try await assertSignedOut([cookieName: .init(string: key.string)])
        try await assertSessionCount(0)
    }

    // MARK: - Cookie

    func testTheCookieLastsAsLongAsTheIdleLimit() async throws {
        let cookies = try await signIn(as: .member)
        let expires = try XCTUnwrap(cookies[cookieName]?.expires)
        let expected = Date().addingTimeInterval(TimeInterval(policy.idleDays) * day)
        XCTAssertEqual(expires.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 60)
    }

    // MARK: - The rule

    func testIsExpiredAtTheIdleBoundary() {
        let now = clock.now
        let limit = TimeInterval(policy.idleDays) * day
        XCTAssertFalse(expired(lastSeen: now - limit + 1, signedIn: now - limit, at: now))
        XCTAssertTrue(expired(lastSeen: now - limit, signedIn: now - limit, at: now))
    }

    func testIsExpiredAtTheMaximumBoundary() {
        let now = clock.now
        let limit = TimeInterval(policy.maxDays) * day
        XCTAssertFalse(expired(lastSeen: now, signedIn: now - limit + 1, at: now))
        XCTAssertTrue(expired(lastSeen: now, signedIn: now - limit, at: now))
    }

    func testMissingOrUnreadableStampsExpireASession() {
        let now = SessionExpiry.stamp(clock.now)
        XCTAssertTrue(SessionExpiry.isExpired(["userId": "x"], now: clock.now, policy: policy))
        XCTAssertTrue(SessionExpiry.isExpired(
            ["userId": "x", SessionExpiry.signedInAtKey: now], now: clock.now, policy: policy))
        XCTAssertTrue(SessionExpiry.isExpired(
            ["userId": "x", SessionExpiry.lastSeenAtKey: now], now: clock.now, policy: policy))
        XCTAssertTrue(SessionExpiry.isExpired(
            ["userId": "x", SessionExpiry.signedInAtKey: now, SessionExpiry.lastSeenAtKey: "last tuesday"],
            now: clock.now, policy: policy))
    }

    func testStampsSurviveARoundTrip() {
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        XCTAssertEqual(SessionExpiry.date(SessionExpiry.stamp(date)), date)
    }

    // MARK: - Configuration

    func testUnsetConfigurationGivesTheDefaults() throws {
        XCTAssertEqual(try SessionExpiry.Policy.load(from: { _ in nil }), .default)
        XCTAssertEqual(try SessionExpiry.Policy.load(from: { _ in " " }), .default)
        XCTAssertEqual(SessionExpiry.Policy.default, .init(idleDays: 7, maxDays: 30))
    }

    func testValidConfigurationIsRead() throws {
        let policy = try SessionExpiry.Policy.load(from: env(idle: "3", max: "3"))
        XCTAssertEqual(policy, .init(idleDays: 3, maxDays: 3))
    }

    func testInvalidConfigurationFailsAtBoot() {
        for (idle, max) in [("0", nil), (nil, "0"), ("seven", nil), ("1.5", nil), ("-1", nil),
                            ("10", "5"), (nil, "5")] as [(String?, String?)] {
            XCTAssertThrowsError(
                try SessionExpiry.Policy.load(from: env(idle: idle, max: max)),
                "idle=\(idle ?? "unset") max=\(max ?? "unset")"
            ) { error in
                XCTAssertTrue(error is ConfigurationError)
            }
        }
    }

    // MARK: - Helpers

    private func env(idle: String?, max: String?) -> (String) -> String? {
        { key in
            switch key {
            case "SESSION_IDLE_DAYS": idle
            case "SESSION_MAX_DAYS": max
            default: nil
            }
        }
    }

    private func expired(lastSeen: Date, signedIn: Date, at now: Date) -> Bool {
        SessionExpiry.isExpired([
            "userId": "x",
            SessionExpiry.lastSeenAtKey: SessionExpiry.stamp(lastSeen),
            SessionExpiry.signedInAtKey: SessionExpiry.stamp(signedIn),
        ], now: now, policy: policy)
    }

    /// Saves a member's session as one signed in before #93 would be: no stamps.
    private func saveUnstampedSession() async throws -> SessionID {
        let user = User(slackUserId: "U_MEMBER", displayName: "Member", role: .member)
        try await user.save(on: app.db)
        let key = SessionID(string: "from-before-93")
        try await SessionRecord(key: key, data: [
            "userId": try user.requireID().uuidString,
            "userRole": UserRole.member.rawValue,
        ]).save(on: app.db)
        return key
    }

    private func loginToken(for slackId: String) async throws -> String {
        let token = LoginToken(slackUserId: slackId, expiresAt: Date().addingTimeInterval(600))
        try await token.save(on: app.db)
        return try token.requireID().uuidString
    }

    /// Redeems a login link for a new user with `role` and returns the session cookie.
    private func signIn(as role: UserRole) async throws -> HTTPCookies {
        let slackId = role == .admin ? "U_ADMIN" : "U_MEMBER"
        let name = role == .admin ? "Admin" : "Member"
        try await User(slackUserId: slackId, displayName: name, role: role).save(on: app.db)
        let token = try await loginToken(for: slackId)

        var cookies: HTTPCookies = [:]
        try await app.test(.GET, "auth/token/\(token)") { res async in
            XCTAssertEqual(res.status, .seeOther)
            cookies = res.headers.setCookie ?? [:]
        }
        return cookies
    }

    private func assertSignedIn(
        _ cookies: HTTPCookies, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await app.test(.GET, "/", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok, file: file, line: line)
            XCTAssertTrue(res.body.string.contains("Signed in as"), "at \(self.clock.now)", file: file, line: line)
        })
    }

    private func assertSignedOut(
        _ cookies: HTTPCookies, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await app.test(.GET, "/", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok, file: file, line: line)
            XCTAssertFalse(res.body.string.contains("Signed in as"), "at \(self.clock.now)", file: file, line: line)
        })
    }

    private func assertSessionCount(
        _ expected: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let count = try await SessionRecord.query(on: app.db).count()
        XCTAssertEqual(count, expected, "rows in _fluent_sessions", file: file, line: line)
    }

    /// The date stored under `key` in the only session row.
    private func storedStamp(
        _ key: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Date {
        let rows = try await SessionRecord.query(on: app.db).all()
        XCTAssertEqual(rows.count, 1, file: file, line: line)
        return try XCTUnwrap(SessionExpiry.date(rows.first?.data[key]), key, file: file, line: line)
    }
}

/// A clock a test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current += interval }
    }
}
