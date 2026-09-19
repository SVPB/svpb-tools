import Fluent
import Foundation
import Vapor

// MARK: - BoxTokenKeepAlive

/// Renews the Box refresh token on a timer, so it cannot die of disuse.
///
/// Box expires a refresh token 60 days after it was last used, and TNG only presents one
/// when it has a binder to upload. The band goes months between edits to the music, so
/// renewing on *activity* means a quiet winter ends with a dead credential and a manual
/// re-authorisation — which is the chore the connections page exists to abolish. Renewing
/// on a *timer* means a server that is merely running keeps its own access alive: every
/// refresh issues a token with a fresh 60 days on it.
///
/// It doubles as a liveness check, and that is half its value. A revoked token or an
/// unreachable Box currently surfaces when someone next pushes music, which may be two
/// months after it broke; a daily attempt turns that into something noticed within a day —
/// provided somebody is told, which is what the Slack announcement is for.
///
/// Box is the only credential TNG holds that expires from disuse. The Slack bot token and
/// the GitHub webhook secret are static configuration, so this is deliberately about Box
/// rather than a general-purpose keep-alive.
///
/// In-process rather than a cron job on the droplet: TNG being self-contained is a
/// deliberate property of the deployment, and an external timer is one more thing to
/// forget when the droplet is rebuilt.
struct BoxTokenKeepAlive: LifecycleHandler {

    /// Setting key recording whether the last renewal worked, so a change of outcome can
    /// be announced without announcing the same state every day.
    static let healthKey = "box.keepalive.healthy"

    /// How long to wait after boot before the first renewal. Long enough to stay out of
    /// the way of a server coming up, short enough that a deployment proves its Box
    /// access while whoever deployed it is still paying attention.
    static let initialDelay: Duration = .seconds(30)

    /// Hours between renewals, from `BOX_TOKEN_REFRESH_HOURS`. Daily by default; settable
    /// so it can be driven down to minutes for testing without a rebuild.
    static func interval(from environment: @autoclosure () -> String?) -> Duration {
        guard let raw = environment()?.trimmingCharacters(in: .whitespaces),
              let hours = Double(raw), hours > 0 else {
            return .seconds(24 * 60 * 60)
        }
        return .seconds(hours * 60 * 60)
    }

    // MARK: - Lifecycle

    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    func didBoot(_ app: Application) throws {
        // Tests boot the whole application; none of them want a timer reaching for Box.
        guard app.environment != .testing else { return }

        let interval = Self.interval(from: Environment.get("BOX_TOKEN_REFRESH_HOURS"))
        app.logger.notice("[Box] Renewing the refresh token every \(Self.describe(interval))")

        app.storage[TaskKey.self] = Task {
            do {
                try await Task.sleep(for: Self.initialDelay)
            } catch {
                return  // cancelled during the initial delay
            }
            while !Task.isCancelled {
                await Self.renewOnce(app: app)
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return  // cancelled while waiting
                }
            }
        }
    }

    func shutdown(_ app: Application) {
        app.storage[TaskKey.self]?.cancel()
    }

    // MARK: - One pass

    /// Renews the token once and announces a change of outcome.
    ///
    /// Never throws: this runs unattended, and a failure is something to report rather
    /// than something to crash a background task over.
    static func renewOnce(app: Application) async {
        var failure: String?
        do {
            try await app.boxService.renew()
            app.logger.info("[Box] Refresh token renewed on schedule")
        } catch {
            failure = "\(error)"
            app.logger.error("[Box] Scheduled token renewal failed: \(error)")
        }

        let previous: Bool?
        do {
            previous = try await Setting.value(for: healthKey, on: app.db).map { $0 == "true" }
        } catch {
            app.logger.warning("[Box] Could not read the last renewal outcome: \(error)")
            previous = nil
        }

        if let message = announcement(previous: previous, failure: failure) {
            do {
                try await app.slackService.postPlainMessage(message)
            } catch {
                app.logger.warning("[Box] Could not announce the renewal outcome to Slack: \(error)")
            }
        }

        do {
            try await Setting.set(healthKey, to: failure == nil ? "true" : "false", on: app.db)
        } catch {
            app.logger.warning("[Box] Could not record the renewal outcome: \(error)")
        }
    }

    // MARK: - What to say, and when

    /// The Slack message for this renewal, or `nil` when there is nothing new to say.
    ///
    /// Only a *change* is announced. A daily job that reported every success would be
    /// noise nobody reads, and one that reported every failure would turn a fortnight's
    /// outage into a fortnight of identical messages — both of which end with the channel
    /// muted, which is the one outcome that must not happen here.
    ///
    /// A first run that succeeds says nothing: there is no news in a thing that works. A
    /// first run that fails does, because there is.
    static func announcement(previous: Bool?, failure: String?) -> String? {
        switch (previous, failure) {
        case (_, .some(let error)) where previous != false:
            return """
                ⚠️ *Box authorisation is failing.* TNG renews its Box token daily; this \
                attempt did not work, so binder uploads will fail until it is fixed. The \
                token expires 60 days after the last successful renewal.
                ```
                \(error)
                ```
                Check the Connections page on the admin dashboard.
                """
        case (.some(false), .none):
            return "✅ *Box authorisation is working again.* The scheduled token renewal succeeded."
        default:
            // Unchanged: a success after a success, or another day of the same failure.
            return nil
        }
    }

    /// "24 hours", "90 minutes" — for the line logged at boot.
    static func describe(_ interval: Duration) -> String {
        let seconds = Int(interval.components.seconds)
        if seconds % 3600 == 0 { return "\(seconds / 3600) hour(s)" }
        if seconds % 60 == 0 { return "\(seconds / 60) minute(s)" }
        return "\(seconds) second(s)"
    }
}
