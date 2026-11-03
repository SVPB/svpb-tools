import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// The scheduled renewal of the destination's credential (#53; generalised in #86).
///
/// A refresh token dies 60 days after it was last used, and the band goes months between
/// edits to the music — so renewing on activity is not enough, and the timer that renews
/// it regardless is the only thing standing between a quiet winter and a manual
/// re-authorisation. What is tested here is the decision-making: how often it runs, and
/// what it says when the answer changes.
final class DestinationKeepAliveTests: XCTestCase {

    // MARK: - Interval

    func testDefaultsToDaily() {
        XCTAssertEqual(RecurringSchedule.interval(hours: nil), .seconds(86400))
    }

    func testReadsHoursFromTheEnvironment() {
        XCTAssertEqual(RecurringSchedule.interval(hours: "6"), .seconds(6 * 3600))
        XCTAssertEqual(RecurringSchedule.interval(hours: " 6 "), .seconds(6 * 3600),
                       "A value pasted with whitespace is still a number")
        XCTAssertEqual(RecurringSchedule.interval(hours: "0.25"), .seconds(900),
                       "Fractions of an hour, so a test can drive it down to minutes")
    }

    /// A nonsense value must not switch the renewal off — that would be the one failure
    /// nobody notices until the token has already expired.
    func testNonsenseFallsBackToDaily() {
        for value in ["", "   ", "nightly", "0", "-3"] {
            XCTAssertEqual(RecurringSchedule.interval(hours: value), .seconds(86400),
                           "'\(value)' should fall back to the daily default")
        }
    }

    func testIntervalReadsInWholeUnits() {
        XCTAssertEqual(RecurringSchedule.describe(.seconds(86400)), "24 hour(s)")
        XCTAssertEqual(RecurringSchedule.describe(.seconds(900)), "15 minute(s)")
        XCTAssertEqual(RecurringSchedule.describe(.seconds(45)), "45 second(s)")
    }

    /// `DESTINATION_TOKEN_REFRESH_HOURS` is the setting now; the production `.env` still
    /// says `BOX_TOKEN_REFRESH_HOURS`, and has to keep working (#86).
    func testTheIntervalVariableFallsBackToItsBoxName() {
        func interval(_ values: [String: String]) -> Duration {
            DestinationKeepAlive.interval(from: { values[$0] })
        }
        XCTAssertEqual(interval([:]), .seconds(86400))
        XCTAssertEqual(interval(["BOX_TOKEN_REFRESH_HOURS": "6"]), .seconds(6 * 3600))
        XCTAssertEqual(interval(["DESTINATION_TOKEN_REFRESH_HOURS": "2",
                                 "BOX_TOKEN_REFRESH_HOURS": "6"]), .seconds(2 * 3600),
                       "The new name wins when both are set")
        XCTAssertEqual(interval(["DESTINATION_TOKEN_REFRESH_HOURS": "",
                                 "BOX_TOKEN_REFRESH_HOURS": "6"]), .seconds(6 * 3600),
                       ".env.example leaves the new name blank; blank is unset")
    }

    // MARK: - The health key

    /// Box's outcome has always been recorded under this key; a deployment's last
    /// recorded state must still count after the rename.
    func testBoxKeepsItsHealthKey() {
        XCTAssertEqual(DestinationKeepAlive.healthKey(for: "box"), "box.keepalive.healthy")
    }

    // MARK: - What gets announced

    /// Nothing works quietly. There is no news in a thing that is still fine, and a daily
    /// "Box is OK" is how a channel gets muted.
    func testASuccessAfterASuccessSaysNothing() {
        XCTAssertNil(announcement(previous: true, failure: nil))
        XCTAssertNil(announcement(previous: nil, failure: nil),
                     "A first run that works is not news either")
    }

    func testAFailureIsAnnouncedWithTheError() {
        let message = announcement(previous: true, failure: "HTTP 400 from Box")

        let text = try? XCTUnwrap(message)
        XCTAssertTrue(text?.contains("Box authorisation is failing") ?? false, message ?? "nil")
        XCTAssertTrue(text?.contains("HTTP 400 from Box") ?? false,
                      "The error itself has to travel with the alarm")
        XCTAssertTrue(text?.contains("Connections page") ?? false,
                      "And somewhere to go about it")
    }

    /// Box's alarm reads exactly as it did before the keep-alive was generalised (#86).
    func testBoxsFailureMessageIsUnchanged() {
        XCTAssertEqual(announcement(previous: true, failure: "boom"), """
            ⚠️ *Box authorisation is failing.* TNG renews its Box token daily; this \
            attempt did not work, so binder uploads will fail until it is fixed. The \
            token expires 60 days after the last successful renewal.
            ```
            boom
            ```
            Check the Connections page on the admin dashboard.
            """)
    }

    /// A credential that does not expire from disuse has no deadline to warn about.
    func testAFailureWithoutALifetimeNamesNoExpiry() {
        let message = DestinationKeepAlive.announcement(
            previous: true, failure: "boom", name: "Drive", lifetime: nil)

        let text = try? XCTUnwrap(message)
        XCTAssertTrue(text?.hasPrefix("⚠️ *Drive authorisation is failing.*") ?? false, message ?? "nil")
        XCTAssertFalse(text?.contains("expires") ?? true, message ?? "nil")
    }

    /// A first run that fails is news, even with nothing to compare against — a fresh
    /// deployment that was never authorised should say so rather than wait for a push.
    func testAFirstRunThatFailsIsAnnounced() {
        XCTAssertNotNil(announcement(previous: nil, failure: "no refresh token"))
    }

    /// The same failure, every day, for a fortnight, is one message — not fourteen.
    func testAContinuingFailureIsNotRepeated() {
        XCTAssertNil(announcement(previous: false, failure: "still broken"))
    }

    func testRecoveryIsAnnounced() {
        let message = announcement(previous: false, failure: nil)

        XCTAssertEqual(message,
                       "✅ *Box authorisation is working again.* The scheduled token renewal succeeded.")
    }

    /// A recovery made by re-authorising must not claim the scheduled renewal did it (#75).
    func testRecoveryByReauthorisationSaysSo() {
        let message = announcement(previous: false, failure: nil, reason: .reauthorised)

        XCTAssertEqual(message,
                       "✅ *Box authorisation is working again* — re-authorised from the Connections page.")
    }

    /// A first authorisation, or one that replaces a token that was still working, is not
    /// news — the same rule as a renewal.
    func testReauthorisingSomethingThatWorkedSaysNothing() {
        XCTAssertNil(announcement(previous: nil, failure: nil, reason: .reauthorised))
        XCTAssertNil(announcement(previous: true, failure: nil, reason: .reauthorised))
    }

    // MARK: - Recording a re-authorisation

    /// After the channel has been told Box is failing, a re-authorisation clears the flag
    /// and announces the recovery at once rather than at the next renewal — and only once.
    func testReauthorisingAfterAFailureAnnouncesRecoveryOnce() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        try await Setting.set(Self.boxHealth, to: "false", on: app.db)

        let first = await DestinationKeepAlive.record(failure: nil, reason: .reauthorised, for: try box(app), app: app)
        XCTAssertEqual(first,
                       "✅ *Box authorisation is working again* — re-authorised from the Connections page.")
        let health = try await Setting.value(for: Self.boxHealth, on: app.db)
        XCTAssertEqual(health, "true")

        let second = await DestinationKeepAlive.record(failure: nil, reason: .reauthorised, for: try box(app), app: app)
        XCTAssertNil(second, "Re-authorising again is not a second recovery")

        try await app.asyncShutdown()
    }

    /// With no failure on record there is nothing to recover from, so nothing is said —
    /// but the success is still recorded, so a later failure is announced as a change.
    func testReauthorisingWithNoFailureOnRecordSaysNothing() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)

        let message = await DestinationKeepAlive.record(failure: nil, reason: .reauthorised, for: try box(app), app: app)
        XCTAssertNil(message)
        let health = try await Setting.value(for: Self.boxHealth, on: app.db)
        XCTAssertEqual(health, "true")

        try await app.asyncShutdown()
    }

    // MARK: - A pass with nothing configured

    /// The renewal runs unattended, so a server with no Box credentials must record the
    /// failure and carry on rather than take a background task down with it.
    func testAFailedPassRecordsItselfAndDoesNotThrow() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)

        await DestinationKeepAlive.renewOnce(try box(app), app: app)

        let health = try await Setting.value(for: Self.boxHealth, on: app.db)
        XCTAssertEqual(health, "false")

        // A second pass changes nothing and still does not throw: this is the shape of an
        // outage lasting days, and it has to be survivable.
        await DestinationKeepAlive.renewOnce(try box(app), app: app)
        let again = try await Setting.value(for: Self.boxHealth, on: app.db)
        XCTAssertEqual(again, "false")

        try await app.asyncShutdown()
    }

    // MARK: - Helpers

    private static let boxHealth = DestinationKeepAlive.healthKey(for: "box")

    /// Box's own wording, which these messages must keep.
    private func announcement(
        previous: Bool?, failure: String?,
        reason: DestinationKeepAlive.Reason = .scheduledRenewal
    ) -> String? {
        DestinationKeepAlive.announcement(
            previous: previous, failure: failure, reason: reason,
            name: "Box", lifetime: 60 * 86400)
    }

    private func box(_ app: Application) throws -> any AuthorizableDestination {
        try XCTUnwrap(app.authorizableDestination, "Box is the configured destination")
    }
}
