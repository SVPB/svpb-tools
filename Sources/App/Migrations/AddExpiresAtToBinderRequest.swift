import Fluent

/// Adds the `expires_at` column to the `binder_requests` table (#83).
///
/// Stamped when the binder's PDF is written, from the retention period in force at
/// that moment, so the date the builder was shown stays true if an admin later changes
/// the period. Existing rows stay null; the sweeper treats them as expiring at
/// `created_at` plus the current period.
struct AddExpiresAtToBinderRequest: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(BinderRequest.schema)
            .field("expires_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BinderRequest.schema)
            .deleteField("expires_at")
            .update()
    }
}
