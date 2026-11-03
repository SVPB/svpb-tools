import Fluent
import Foundation

/// Stamps the sessions signed in before #93 with the time it runs, which is the deploy.
///
/// Those sessions recorded no times, and a session without stamps is expired. Stamping
/// them here, once, gives everyone signed in at the deploy a full period from the deploy:
/// nobody is signed out by it, and a session nobody uses afterwards expires on schedule.
/// Stamping on a session's first request instead would hand a fresh period to a cookie
/// that had lain unused for months, whenever it turned up.
///
/// The first sweep, in effect, run once; #90's sweeper takes over from here.
struct StampExistingSessions: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await SessionExpiry.stampUnstampedSessions(on: database, now: Date())
    }

    /// Nothing to undo: the stamps are harmless to code that doesn't read them.
    func revert(on database: any Database) async throws {}
}
