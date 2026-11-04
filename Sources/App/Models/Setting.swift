import Fluent
import Vapor

/// A single piece of server state that outlives the process but does not belong to
/// any of the domain models — the destinations' OAuth tokens, for instance.
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

    /// The key of the Google Drive refresh token (#88). Google does not rotate it, so it is
    /// written when an authorisation issues one, not on every refresh.
    static let googleDriveRefreshToken = "google_drive.refresh_token"

    /// When the Google Drive credential was last used to renew the access token, as
    /// ISO 8601. Google's six months of disuse count from here, and since the refresh
    /// token itself rarely changes, its row's timestamp cannot say (#88).
    static let googleDriveTokenRenewedAt = "google_drive.token_renewed_at"

    /// The ID of the root folder TNG created in Google Drive on its first publish (#88).
    /// With only the `drive.file` scope TNG cannot see a folder it did not make, so it
    /// makes its own and remembers it here.
    static let googleDriveRootFolderID = "google_drive.root_folder_id"

    /// The key of the binder retention period in days, when an admin has set one (#83).
    /// Overrides `BINDER_RETENTION_DAYS`.
    static let binderRetentionDays = "binders.retention_days"

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
