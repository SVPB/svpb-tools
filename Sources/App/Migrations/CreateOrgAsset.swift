import Fluent

/// The organisation's uploaded artwork (#89).
struct CreateOrgAsset: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(OrgAsset.schema)
            // Primary key: the slot, e.g. "logo".
            .field("slot", .string, .identifier(auto: false))
            .field("content_type", .string, .required)
            .field("bytes", .data, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(OrgAsset.schema).delete()
    }
}
