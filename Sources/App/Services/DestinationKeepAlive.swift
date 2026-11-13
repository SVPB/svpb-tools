import Fluent
import Foundation
import Vapor

// MARK: - DestinationKeepAlive

/// Renews the publishing destination's OAuth credential on a timer, so it cannot die of
/// disuse (#53, generalised in #86).
///
/// Box expires a refresh token 60 days after it was last used, and TNG only presents one
/// when it has a binder to upload. The band goes months between edits to the music, so
/// renewing on *activity* means a quiet winter ends with a dead credential and a manual
/// re-authorisation — which is the chore the connections page exists to abolish. Renewing
/// on a *timer* means a server that is merely running keeps its own access alive: every
/// refresh issues a token with a fresh 60 days on it. Google's refresh tokens last about
/// six months unused; daily suits both.
///
/// It doubles as a liveness check, and that is half its value. A revoked token or an
/// unreachable destination otherwise surfaces when someone next pushes music, which may
/// be two months after it broke; a daily attempt turns that into something noticed within
/// a day — provided somebody is told, which is what the Slack announcement is for.
///
/// It runs only for an `AuthorizableDestination`. A destination with fixed keys has
/// nothing to renew, and the Slack bot token and the GitHub webhook secret are static
/// configuration, so this is about the destination's grant rather than a general-purpose
/// keep-alive.
///
/// In-process rather than a cron job on the droplet: TNG being self-contained is a
/// deliberate property of the deployment, and an external timer is one more thing to
/// forget when the droplet is rebuilt.
struct DestinationKeepAlive: LifecycleHandler {

    let destination: any AuthorizableDestination

    /// Setting key recording whether the last renewal of `destinationID`'s credential
    /// worked, so a change of outcome can be announced without announcing the same state
    /// every day. Box's is `box.keepalive.healthy`, the key it has always had.
    static func healthKey(for destinationID: String) -> String {
        "\(destinationID).keepalive.healthy"
    }

    /// How long to wait after boot before the first renewal. Long enough to stay out of
    /// the way of a server coming up, short enough that a deployment proves its access
    /// while whoever deployed it is still paying attention.
    static let initialDelay: Duration = .seconds(30)

    /// The variable that sets the interval, in hours.
    static let intervalVariable = "DESTINATION_TOKEN_REFRESH_HOURS"
    /// Its name before #86, still read when the new one is unset, so an existing `.env`
    /// keeps its setting.
    static let legacyIntervalVariable = "BOX_TOKEN_REFRESH_HOURS"

    /// Hours between renewals: `DESTINATION_TOKEN_REFRESH_HOURS`, else
    /// `BOX_TOKEN_REFRESH_HOURS`, else daily. Settable so it can be driven down to
    /// minutes for testing without a rebuild.
    static func interval(from environment: (String) -> String? = Environment.get) -> Duration {
        for name in [intervalVariable, legacyIntervalVariable] {
            if let raw = environment(name)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
                return RecurringSchedule.interval(hours: raw)
            }
        }
        return RecurringSchedule.interval(hours: nil)
    }

    // MARK: - Lifecycle

    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    func didBoot(_ app: Application) throws {
        // Tests boot the whole application; none of them want a timer reaching for a
        // real service.
        guard app.environment != .testing else { return }

        let destination = self.destination
        let interval = Self.interval()
        app.logger.notice("[\(destination.displayName)] Renewing the credential every \(RecurringSchedule.describe(interval))")

        app.storage[TaskKey.self] = Task {
            do {
                try await Task.sleep(for: Self.initialDelay)
            } catch {
                return  // cancelled during the initial delay
            }
            while !Task.isCancelled {
                await Self.renewOnce(destination, app: app)
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

    /// Renews the credential once and announces a change of outcome.
    ///
    /// Never throws: this runs unattended, and a failure is something to report rather
    /// than something to crash a background task over.
    static func renewOnce(_ destination: any AuthorizableDestination, app: Application) async {
        var failure: String?
        do {
            try await destination.renew()
            app.logger.info("[\(destination.displayName)] Credential renewed on schedule")
        } catch {
            failure = "\(error)"
            app.logger.error("[\(destination.displayName)] Scheduled credential renewal failed: \(error)")
        }
        await record(failure: failure, reason: .scheduledRenewal, for: destination, app: app)
    }

    // MARK: - Recording an outcome

    /// What produced an outcome, which is what the recovery message has to name.
    enum Reason: Sendable {
        /// The timer's own renewal.
        case scheduledRenewal
        /// An operator re-authorised the destination from the Connections page.
        case reauthorised
    }

    /// Announces `failure` (or its absence) if it differs from the last recorded outcome,
    /// then records it.
    ///
    /// The one place that reads or writes the health key. The scheduled renewal calls it
    /// with whatever happened; the authorisation callback calls it only on success, so a
    /// re-authorisation that fixes the destination says so straight away instead of
    /// leaving the channel's last word on it an alarm until the next renewal, up to a day
    /// later. A failed authorisation is not recorded: an abandoned consent window is not
    /// news, and the person who pressed the button already sees the error.
    ///
    /// - Returns: The message announced, if any — whether or not Slack accepted it.
    @discardableResult
    static func record(
        failure: String?, reason: Reason,
        for destination: any AuthorizableDestination, app: Application
    ) async -> String? {
        let name = destination.displayName
        let key = healthKey(for: destination.id)
        let previous: Bool?
        do {
            previous = try await Setting.value(for: key, on: app.db).map { $0 == "true" }
        } catch {
            app.logger.warning("[\(name)] Could not read the last renewal outcome: \(error)")
            previous = nil
        }

        let message = announcement(
            previous: previous, failure: failure, reason: reason,
            name: name, lifetime: destination.credentialLifetime)
        if let message {
            do {
                try await app.slackService.postPlainMessage(message)
            } catch {
                app.logger.warning("[\(name)] Could not announce the renewal outcome to Slack: \(error)")
            }
        }

        do {
            try await Setting.set(key, to: failure == nil ? "true" : "false", on: app.db)
        } catch {
            app.logger.warning("[\(name)] Could not record the renewal outcome: \(error)")
        }
        return message
    }

    // MARK: - What to say, and when

    /// The Slack message for this outcome, or `nil` when there is nothing new to say.
    ///
    /// Only a *change* is announced. A daily job that reported every success would be
    /// noise nobody reads, and one that reported every failure would turn a fortnight's
    /// outage into a fortnight of identical messages — both of which end with the channel
    /// muted, which is the one outcome that must not happen here.
    ///
    /// A first run that succeeds says nothing: there is no news in a thing that works. A
    /// first run that fails does, because there is.
    ///
    /// `reason` changes only what a recovery says. A failure is only ever recorded by the
    /// scheduled renewal, so the failure text speaks for that alone.
    ///
    /// - Parameters:
    ///   - name: The destination's `displayName`.
    ///   - lifetime: Its `credentialLifetime`; the failure says when the credential runs
    ///     out, when it does.
    static func announcement(
        previous: Bool?, failure: String?, reason: Reason = .scheduledRenewal,
        name: String, lifetime: TimeInterval?
    ) -> String? {
        switch (previous, failure) {
        case (_, .some(let error)) where previous != false:
            let expiry = lifetime.map {
                " The token expires \(Int($0 / 86400)) days after the last successful renewal."
            } ?? ""
            return """
                ⚠️ *\(name) authorisation is failing.* TNG renews its \(name) token daily; this \
                attempt did not work, so binder uploads will fail until it is fixed.\(expiry)
                ```
                \(error)
                ```
                Check the Connections page on the admin dashboard.
                """
        case (.some(false), .none):
            switch reason {
            case .scheduledRenewal:
                return "✅ *\(name) authorisation is working again.* The scheduled token renewal succeeded."
            case .reauthorised:
                return "✅ *\(name) authorisation is working again* — re-authorised from the Connections page."
            }
        default:
            // Unchanged: a success after a success, or another day of the same failure.
            return nil
        }
    }
}
