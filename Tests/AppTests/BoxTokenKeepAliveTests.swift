import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// The scheduled Box token renewal (#53).
///
/// A refresh token dies 60 days after it was last used, and the band goes months between
/// edits to the music — so renewing on activity is not enough, and the timer that renews
/// it regardless is the only thing standing between a quiet winter and a manual
/// re-authorisation. What is tested here is the decision-making: how often it runs, and
/// what it says when the answer changes.
final class BoxTokenKeepAliveTests: XCTestCase {

    // MARK: - Interval

    func testDefaultsToDaily() {
        XCTAssertEqual(BoxTokenKeepAlive.interval(from: nil), .seconds(86400))
    }

    func testReadsHoursFromTheEnvironment() {
        XCTAssertEqual(BoxTokenKeepAlive.interval(from: "6"), .seconds(6 * 3600))
        XCTAssertEqual(BoxTokenKeepAlive.interval(from: " 6 "), .seconds(6 * 3600),
                       "A value pasted with whitespace is still a number")
        XCTAssertEqual(BoxTokenKeepAlive.interval(from: "0.25"), .seconds(900),
                       "Fractions of an hour, so a test can drive it down to minutes")
    }

    /// A nonsense value must not switch the renewal off — that would be the one failure
    /// nobody notices until the token has already expired.
    func testNonsenseFallsBackToDaily() {
        for value in ["", "   ", "nightly", "0", "-3"] {
            XCTAssertEqual(BoxTokenKeepAlive.interval(from: value), .seconds(86400),
                           "'\(value)' should fall back to the daily default")
        }
    }

    func testIntervalReadsInWholeUnits() {
        XCTAssertEqual(BoxTokenKeepAlive.describe(.seconds(86400)), "24 hour(s)")
        XCTAssertEqual(BoxTokenKeepAlive.describe(.seconds(900)), "15 minute(s)")
        XCTAssertEqual(BoxTokenKeepAlive.describe(.seconds(45)), "45 second(s)")
    }

    // MARK: - What gets announced

    /// Nothing works quietly. There is no news in a thing that is still fine, and a daily
    /// "Box is OK" is how a channel gets muted.
    func testASuccessAfterASuccessSaysNothing() {
        XCTAssertNil(BoxTokenKeepAlive.announcement(previous: true, failure: nil))
        XCTAssertNil(BoxTokenKeepAlive.announcement(previous: nil, failure: nil),
                     "A first run that works is not news either")
    }

    func testAFailureIsAnnouncedWithTheError() {
        let message = BoxTokenKeepAlive.announcement(previous: true, failure: "HTTP 400 from Box")

        let text = try? XCTUnwrap(message)
        XCTAssertTrue(text?.contains("Box authorisation is failing") ?? false, message ?? "nil")
        XCTAssertTrue(text?.contains("HTTP 400 from Box") ?? false,
                      "The error itself has to travel with the alarm")
        XCTAssertTrue(text?.contains("Connections page") ?? false,
                      "And somewhere to go about it")
    }

    /// A first run that fails is news, even with nothing to compare against — a fresh
    /// deployment that was never authorised should say so rather than wait for a push.
    func testAFirstRunThatFailsIsAnnounced() {
        XCTAssertNotNil(BoxTokenKeepAlive.announcement(previous: nil, failure: "no refresh token"))
    }

    /// The same failure, every day, for a fortnight, is one message — not fourteen.
    func testAContinuingFailureIsNotRepeated() {
        XCTAssertNil(BoxTokenKeepAlive.announcement(previous: false, failure: "still broken"))
    }

    func testRecoveryIsAnnounced() {
        let message = BoxTokenKeepAlive.announcement(previous: false, failure: nil)

        XCTAssertEqual(message,
                       "✅ *Box authorisation is working again.* The scheduled token renewal succeeded.")
    }

    // MARK: - A pass with nothing configured

    /// The renewal runs unattended, so a server with no Box credentials must record the
    /// failure and carry on rather than take a background task down with it.
    func testAFailedPassRecordsItselfAndDoesNotThrow() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)

        await BoxTokenKeepAlive.renewOnce(app: app)

        let health = try await Setting.value(for: BoxTokenKeepAlive.healthKey, on: app.db)
        XCTAssertEqual(health, "false")

        // A second pass changes nothing and still does not throw: this is the shape of an
        // outage lasting days, and it has to be survivable.
        await BoxTokenKeepAlive.renewOnce(app: app)
        let again = try await Setting.value(for: BoxTokenKeepAlive.healthKey, on: app.db)
        XCTAssertEqual(again, "false")

        try await app.asyncShutdown()
    }
}
