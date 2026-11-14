import Fluent
import Foundation

/// A piece of the organisation's artwork, uploaded on the Organisation admin page (#89).
///
/// Kept in the database rather than on disk because the database is what is copied off the
/// server every night (``DatabaseBackup``), so uploaded artwork is backed up with nothing
/// new to remember. A slot with no row is served TNG's built-in neutral image.
final class OrgAsset: Model, @unchecked Sendable {

    static let schema = "org_assets"

    /// Where a piece of artwork is used.
    enum Slot: String, CaseIterable, Codable, Sendable {
        /// The header logo, `/img/logo`.
        case logo
        /// The browser-tab icon, `/favicon.ico` and `/favicon.svg`.
        case favicon
        /// The icon iOS uses for a home-screen bookmark, `/apple-touch-icon.png`.
        case touchIcon = "touch_icon"
    }

    // MARK: - Fields

    /// The slot's raw value. Acts as the primary key: one image per slot.
    @ID(custom: "slot", generatedBy: .user)
    var id: String?

    /// The type the bytes were recognised as on upload, e.g. `image/svg+xml`.
    @Field(key: "content_type")
    var contentType: String

    /// Exactly what was uploaded.
    @Field(key: "bytes")
    var bytes: Data

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    // MARK: - Lifecycle

    init() {}

    init(slot: Slot, contentType: String, bytes: Data) {
        self.id = slot.rawValue
        self.contentType = contentType
        self.bytes = bytes
    }

    // MARK: - Convenience

    /// The upload in `slot`, or `nil` when there is none.
    static func find(_ slot: Slot, on db: any Database) async throws -> OrgAsset? {
        try await OrgAsset.find(slot.rawValue, on: db)
    }

    /// Stores `bytes` in `slot`, replacing whatever was there.
    static func store(
        _ bytes: Data, contentType: String, in slot: Slot, on db: any Database
    ) async throws {
        if let existing = try await find(slot, on: db) {
            existing.contentType = contentType
            existing.bytes = bytes
            try await existing.save(on: db)
        } else {
            try await OrgAsset(slot: slot, contentType: contentType, bytes: bytes).create(on: db)
        }
    }
}
