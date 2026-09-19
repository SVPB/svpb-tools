import Fluent
import Vapor

/// A single piece of server state that outlives the process but does not belong to
/// any of the domain models — currently the rotated Box refresh token.
///
/// The `.env` file seeds configuration; this table holds the values the server itself
/// changes at runtime. A Box refresh token is the motivating case: Box issues a new one
/// on every refresh and invalidates the old, so the value in `.env` is correct exactly
/// once. Keeping the current one only in memory meant every restart reached for a token
/// Box had already retired, and a token unused for 60 days expires outright.
final class Setting: Model, @unchecked Sendable {

    static let schema = "settings"

    /// The key of the Box refresh token, rotated on every token refresh.
    static let boxRefreshToken = "box.refresh_token"

    // MARK: - Fields

    /// Dotted key, e.g. `box.refresh_token`. Acts as the primary key.
    @ID(custom: "key", generatedBy: .user)
    var id: String?

    @Field(key: "value")
    var value: String

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    // MARK: - Lifecycle

    init() {}

    init(key: String, value: String) {
        self.id = key
        self.value = value
    }

    // MARK: - Convenience

    /// The stored value for `key`, or `nil` when nothing has been stored under it.
    static func value(for key: String, on db: any Database) async throws -> String? {
        try await Setting.find(key, on: db)?.value
    }

    /// Stores `value` under `key`, replacing whatever was there.
    ///
    /// Fluent's `save` inserts or updates by whether the model believes it is new, which
    /// a freshly constructed one always does, so the row is looked up first.
    static func set(_ key: String, to value: String, on db: any Database) async throws {
        if let existing = try await Setting.find(key, on: db) {
            existing.value = value
            try await existing.save(on: db)
        } else {
            try await Setting(key: key, value: value).create(on: db)
        }
    }
}
