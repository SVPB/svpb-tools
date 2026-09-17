import Fluent

struct CreatePart: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(Part.schema)
            .id()
            .field("tune_id", .uuid, .required, .references(Tune.schema, "id", onDelete: .cascade))
            // Part names are unique within a tune (you can't have two "Melody" parts).
            .field("name", .string, .required)
            // Populated by the build pipeline once the PDF has been generated.
            .field("pdf_path", .string)
            .unique(on: "tune_id", "name")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Part.schema).delete()
    }
}
