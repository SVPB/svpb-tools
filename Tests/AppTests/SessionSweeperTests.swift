import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// The sweeper deletes every session that can no longer sign anyone in, by #93's rule,
/// and nothing else (#90).
final class SessionSweeperTests: XCTestCase {

    var app: Application!

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60
    private let policy = SessionExpiry.Policy.default
    private var member: User!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        member = User(slackUserId: "U_MEMBER", displayName: "Member", role: .member)
        try await member.save(on: app.db)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testLiveSessionsAreLeftAlone() async throws {
        try await save("fresh", signedIn: now - day, lastSeen: now - 60)
        try await save("nearly-idle", signedIn: now - day * 8, lastSeen: now - idle + 60)
        try await save("nearly-max", signedIn: now - max + 60, lastSeen: now)

        let summary = try await sweep()
        XCTAssertTrue(summary.isEmpty)
        try await assertRemaining(["fresh", "nearly-idle", "nearly-max"])
    }

    func testSessionsPastEitherLimitAreDeleted() async throws {
        try await save("live", signedIn: now - day, lastSeen: now)
        try await save("idle", signedIn: now - day * 10, lastSeen: now - idle)
        try await save("past-max", signedIn: now - max, lastSeen: now - 60)

        let summary = try await sweep()
        XCTAssertEqual(summary, .init(anonymous: 0, orphaned: 0, expired: 2))
        try await assertRemaining(["live"])
    }

    func testSessionsOfDeletedUsersAreDeleted() async throws {
        try await save("live", signedIn: now, lastSeen: now)
        try await save("orphan", userId: UUID().uuidString, signedIn: now, lastSeen: now)

        let summary = try await sweep()
        XCTAssertEqual(summary, .init(anonymous: 0, orphaned: 1, expired: 0))
        try await assertRemaining(["live"])
    }

    /// Including the empty rows #92's bug left behind.
    func testSessionsWithNoUserAreDeleted() async throws {
        try await save("live", signedIn: now, lastSeen: now)
        try await SessionRecord(key: SessionID(string: "empty"), data: [:]).save(on: app.db)
        try await SessionRecord(key: SessionID(string: "box-state-only"), data: ["boxState": "x"]).save(on: app.db)
        try await save("not-a-uuid", userId: "garbage", signedIn: now, lastSeen: now)

        let summary = try await sweep()
        XCTAssertEqual(summary, .init(anonymous: 3, orphaned: 0, expired: 0))
        try await assertRemaining(["live"])
    }

    /// `StampExistingSessions` stamped every session from before #93, and every sign-in is
    /// stamped, so a row still without stamps is one whose age can't be known. The
    /// request check already refuses it; the sweeper agrees.
    func testASessionWithNoStampsIsDeletedAsTheRequestCheckWouldRefuseIt() async throws {
        let data: SessionData = ["userId": try member.requireID().uuidString]
        XCTAssertTrue(SessionExpiry.isExpired(data, now: now, policy: policy))
        try await SessionRecord(key: SessionID(string: "unstamped"), data: data).save(on: app.db)

        let summary = try await sweep()
        XCTAssertEqual(summary.expired, 1)
        try await assertRemaining([])
    }

    func testTheSweepAgreesWithTheRequestCheck() async throws {
        let offsets: [TimeInterval] = [0, 60, idle - 1, idle, idle + 1, max - 1, max, max + 1]
        var expected: [String] = []
        for signedIn in offsets {
            for lastSeen in offsets where lastSeen <= signedIn {
                let key = "s\(Int(signedIn))-l\(Int(lastSeen))"
                let data = try stamped(signedIn: now - signedIn, lastSeen: now - lastSeen)
                if !SessionExpiry.isExpired(data, now: now, policy: policy) { expected.append(key) }
                try await SessionRecord(key: SessionID(string: key), data: data).save(on: app.db)
            }
        }
        _ = try await sweep()
        try await assertRemaining(expected)
    }

    func testSweepOnceUsesTheApplicationsClockAndPolicy() async throws {
        try await save("idle", signedIn: now - idle, lastSeen: now - idle)
        let now = self.now
        app.sessionClock = { now }
        await SessionSweeper.sweepOnce(app: app)
        try await assertRemaining([])
    }

    // MARK: - Helpers

    private var idle: TimeInterval { TimeInterval(policy.idleDays) * day }
    private var max: TimeInterval { TimeInterval(policy.maxDays) * day }

    private func sweep() async throws -> SessionSweeper.Summary {
        try await SessionSweeper.sweep(on: app.db, now: now, policy: policy)
    }

    private func stamped(userId: String? = nil, signedIn: Date, lastSeen: Date) throws -> SessionData {
        [
            "userId": try userId ?? member.requireID().uuidString,
            "userRole": UserRole.member.rawValue,
            SessionExpiry.signedInAtKey: SessionExpiry.stamp(signedIn),
            SessionExpiry.lastSeenAtKey: SessionExpiry.stamp(lastSeen),
        ]
    }

    private func save(_ key: String, userId: String? = nil, signedIn: Date, lastSeen: Date) async throws {
        try await SessionRecord(
            key: SessionID(string: key),
            data: try stamped(userId: userId, signedIn: signedIn, lastSeen: lastSeen)
        ).save(on: app.db)
    }

    private func assertRemaining(
        _ keys: [String], file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let remaining = try await SessionRecord.query(on: app.db).all().map(\.key.string)
        XCTAssertEqual(Set(remaining), Set(keys), file: file, line: line)
    }
}
