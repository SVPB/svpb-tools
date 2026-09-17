import Fluent

/// Adds the `svg_paths` column to the `parts` table.
///
/// This column stores a JSON-encoded `[String]` of absolute paths to the
/// per-page SVG files for a part, enabling binder assembly without re-running
/// the ABC-to-SVG conversion pipeline.
struct AddSvgPathsToPart: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(Part.schema)
            .field("svg_paths", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Part.schema)
            .deleteField("svg_paths")
            .update()
    }
}
