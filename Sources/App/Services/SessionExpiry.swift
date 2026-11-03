import Fluent
import Foundation
import Vapor

// MARK: - SessionExpiry

/// When a sign-in stops signing anyone in (#93).
///
/// A session ends once it has gone unused for the idle limit, or once the absolute limit
/// has passed since sign-in, whichever comes first. Before this the server checked
/// neither: the only expiry was the browser forgetting its cookie a week after the last
/// request, so a copied cookie value never expired, and a browser in daily use never had
/// to sign in again.
///
/// The session records its own times, as ISO 8601 strings in its `SessionData`:
///
///   - ``signedInAtKey`` — written by `AuthController` when a login link is redeemed;
///   - ``lastSeenAtKey`` — written by `SessionExpiryMiddleware` on every request from a
///     signed-in session, the sign-in's own included.
///
/// Sessions from before #93 were stamped with the time of the deploy by the
/// `StampExistingSessions` migration, so their limits count from the deploy, not from
/// whenever their cookie happens to be presented again.
///
/// ``isExpired(_:now:policy:)`` is the whole rule, so the middleware that enforces it and
/// anything that sweeps expired rows (#90) cannot disagree about what "expired" means.
enum SessionExpiry {

    /// Session data key for when the session was signed in.
    static let signedInAtKey = "signedInAt"

    /// Session data key for the last request the session made.
    static let lastSeenAtKey = "lastSeenAt"

    // MARK: Policy

    /// The two limits, in whole days.
    struct Policy: Equatable, Sendable {
        /// Days a session may go unused. `SESSION_IDLE_DAYS`.
        let idleDays: Int
        /// Days a session may last from sign-in, however much it is used. `SESSION_MAX_DAYS`.
        let maxDays: Int

        /// Seven days idle — what the browser's cookie lifetime enforced before — and a
        /// month in all, so a band member signs in from Slack about once a month.
        static let `default` = Policy(idleDays: 7, maxDays: 30)

        var idleInterval: TimeInterval { Self.interval(days: idleDays) }
        var maxInterval: TimeInterval { Self.interval(days: maxDays) }

        private static func interval(days: Int) -> TimeInterval {
            TimeInterval(days) * 24 * 60 * 60
        }

        /// Reads `SESSION_IDLE_DAYS` and `SESSION_MAX_DAYS`, each defaulting when unset or
        /// blank. Throws for a value that is not a whole number of days, at least 1, or
        /// for an idle limit longer than the maximum: either would be a sign-in policy
        /// nobody chose, so the server refuses to start rather than guess.
        static func load(from environment: (String) -> String?) throws -> Policy {
            let idle = try days(environment, "SESSION_IDLE_DAYS", default: Self.default.idleDays)
            let max = try days(environment, "SESSION_MAX_DAYS", default: Self.default.maxDays)
            guard idle <= max else {
                throw ConfigurationError(description:
                    "SESSION_IDLE_DAYS (\(idle)) is longer than SESSION_MAX_DAYS (\(max)); "
                    + "a session cannot stay idle longer than it may last.")
            }
            return Policy(idleDays: idle, maxDays: max)
        }

        private static func days(
            _ environment: (String) -> String?, _ key: String, default fallback: Int
        ) throws -> Int {
            guard let raw = environment(key)?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty else {
                return fallback
            }
            guard let days = Int(raw), days >= 1 else {
                throw ConfigurationError(description:
                    "\(key) must be a whole number of days, at least 1; it is '\(raw)'.")
            }
            return days
        }
    }

    // MARK: The rule

    /// Whether a session with `data` has expired at `now`.
    ///
    /// A limit is reached at its exact boundary: a session last seen exactly
    /// `idleDays` ago is expired. A session missing either stamp, or holding one that
    /// can't be read, is expired: every sign-in is stamped as it is made, and
    /// `StampExistingSessions` stamped the sessions from before #93, so a session
    /// without stamps is one whose age can't be known.
    static func isExpired(_ data: SessionData, now: Date, policy: Policy) -> Bool {
        guard let lastSeen = date(data[lastSeenAtKey]),
              let signedIn = date(data[signedInAtKey]) else {
            return true
        }
        return now.timeIntervalSince(lastSeen) >= policy.idleInterval
            || now.timeIntervalSince(signedIn) >= policy.maxInterval
    }

    // MARK: Stamps

    /// `date` as it is stored in session data.
    static func stamp(_ date: Date) -> String {
        date.formatted(stampStyle)
    }

    /// Stamps every signed-in session that has no stamps with `now`, and returns how many.
    /// Run once, by `StampExistingSessions`, for the sessions signed in before #93.
    @discardableResult
    static func stampUnstampedSessions(on db: any Database, now: Date) async throws -> Int {
        let stamp = stamp(now)
        var count = 0
        for record in try await SessionRecord.query(on: db).all() {
            var data = record.data
            guard data["userId"] != nil,
                  data[signedInAtKey] == nil || data[lastSeenAtKey] == nil else { continue }
            data[signedInAtKey] = data[signedInAtKey] ?? stamp
            data[lastSeenAtKey] = data[lastSeenAtKey] ?? stamp
            record.data = data
            try await record.save(on: db)
            count += 1
        }
        return count
    }

    /// The date a stored stamp names, or `nil` for a missing or unreadable one.
    static func date(_ stamp: String?) -> Date? {
        guard let stamp else { return nil }
        return (try? stampStyle.parse(stamp))
            ?? (try? Date.ISO8601FormatStyle().parse(stamp))
    }

    // MARK: Cookie

    /// Vapor's default session cookie, except that it expires `policy.idleDays` from now
    /// rather than a week. The factory sees only the session ID, so the cookie can follow
    /// the idle limit but not the absolute one; the server enforces that.
    ///
    /// `SameSite=Lax`, and neither `HttpOnly` nor `Secure`, as Vapor's default has them
    /// (the flags are #94).
    static func sessionsConfiguration(policy: Policy) -> SessionsConfiguration {
        let lifetime = policy.idleInterval
        return SessionsConfiguration(cookieName: "vapor-session") { sessionID in
            HTTPCookies.Value(
                string: sessionID.string,
                expires: Date(timeIntervalSinceNow: lifetime),
                maxAge: nil,
                domain: nil,
                path: "/",
                isSecure: false,
                isHTTPOnly: false,
                sameSite: .lax
            )
        }
    }
}

private let stampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

// MARK: - Application storage

extension Application {

    private struct SessionExpiryPolicyKey: StorageKey { typealias Value = SessionExpiry.Policy }
    private struct SessionClockKey: StorageKey { typealias Value = @Sendable () -> Date }

    /// The session limits in force, read from the environment in `configure`.
    var sessionExpiryPolicy: SessionExpiry.Policy {
        get { storage[SessionExpiryPolicyKey.self] ?? .default }
        set { storage[SessionExpiryPolicyKey.self] = newValue }
    }

    /// The time session stamps are written and judged against. The system clock, except
    /// in tests that need a session to grow old.
    var sessionClock: @Sendable () -> Date {
        get { storage[SessionClockKey.self] ?? { Date() } }
        set { storage[SessionClockKey.self] = newValue }
    }
}
