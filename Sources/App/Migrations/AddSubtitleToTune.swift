import Fluent

/// Adds the `subtitle` column to the `tunes` table.
///
/// Holds the first tune's `T:` values after the title, so the catalogue can
/// tell apart files that engrave variants of the same tune. Existing rows stay
/// null until the next build re-extracts them.
struct AddSubtitleToTune: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(Tune.schema)
            .field("subtitle", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Tune.schema)
            .deleteField("subtitle")
            .update()
    }
}
