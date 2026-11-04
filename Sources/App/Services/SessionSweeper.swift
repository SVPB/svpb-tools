import Fluent
import Foundation
import Vapor

// MARK: - SessionSweeper

/// Deletes the sessions that can no longer sign anyone in (#90).
///
/// `SessionExpiryMiddleware` refuses an expired session when it is presented (#93), but a
/// session that is never presented again — a browser that stopped coming back — would
/// otherwise stay in `_fluent_sessions` for good. Each sweep deletes a row that:
///
///   - has expired, by `SessionExpiry.isExpired` and never by a rule of its own, so the
///     sweeper and the per-request check cannot disagree. That includes a row with no
///     stamps: every sign-in is stamped, and `StampExistingSessions` stamped the sessions
///     from before #93, so such a row is one whose age can't be known;
///   - belongs to a user who no longer exists;
///   - has no `userId` at all, such as the empty rows #92's bug left behind.
///
/// In-process for the same reason as `BinderCache`: an external timer is one more thing
/// to forget when the droplet is rebuilt.
struct SessionSweeper: LifecycleHandler {

    /// How long to wait after boot before the first sweep.
    static let initialDelay: Duration = .seconds(60)

    /// Time between sweeps. A dead row outliving its expiry by up to an hour signs nobody in.
    static let sweepInterval: Duration = .seconds(60 * 60)

    // MARK: - Lifecycle

    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    func didBoot(_ app: Application) throws {
        // Tests boot the whole application; none of them want a timer deleting sessions.
        guard app.environment != .testing else { return }

        app.logger.notice("[SessionSweeper] Sweeping ended sessions every \(RecurringSchedule.describe(Self.sweepInterval))")

        app.storage[TaskKey.self] = Task {
            do {
                try await Task.sleep(for: Self.initialDelay)
            } catch {
                return  // cancelled during the initial delay
            }
            while !Task.isCancelled {
                await Self.sweepOnce(app: app)
                do {
                    try await Task.sleep(for: Self.sweepInterval)
                } catch {
                    return  // cancelled while waiting
                }
            }
        }
    }

    func shutdown(_ app: Application) {
        app.storage[TaskKey.self]?.cancel()
    }

    /// Sweeps once and logs what went. Never throws: this runs unattended.
    static func sweepOnce(app: Application) async {
        do {
            let summary = try await sweep(
                on: app.db, now: app.sessionClock(), policy: app.sessionExpiryPolicy)
            if summary.isEmpty {
                app.logger.debug("[SessionSweeper] No sessions have ended")
            } else {
                app.logger.notice("[SessionSweeper] Removed \(summary.expired) expired session(s), \(summary.orphaned) of deleted users and \(summary.anonymous) with no user")
            }
        } catch {
            app.logger.error("[SessionSweeper] Sweep failed: \(error)")
        }
    }

    // MARK: - Sweeping

    /// What one sweep removed, by reason. A row is counted under the first that applies,
    /// in this order.
    struct Summary: Equatable, Sendable {
        /// Rows with no `userId`, or one that is not a user ID.
        var anonymous = 0
        /// Rows whose user no longer exists.
        var orphaned = 0
        /// Rows past either of #93's limits.
        var expired = 0

        var total: Int { anonymous + orphaned + expired }
        var isEmpty: Bool { total == 0 }
    }

    /// Deletes every session that cannot sign anyone in at `now`.
    static func sweep(
        on db: any Database, now: Date, policy: SessionExpiry.Policy
    ) async throws -> Summary {
        let userIds = Set(try await User.query(on: db).all().compactMap(\.id))
        var summary = Summary()
        for record in try await SessionRecord.query(on: db).all() {
            guard let userId = record.data["userId"].flatMap(UUID.init(uuidString:)) else {
                try await record.delete(on: db)
                summary.anonymous += 1
                continue
            }
            if !userIds.contains(userId) {
                try await record.delete(on: db)
                summary.orphaned += 1
            } else if SessionExpiry.isExpired(record.data, now: now, policy: policy) {
                try await record.delete(on: db)
                summary.expired += 1
            }
        }
        return summary
    }
}
