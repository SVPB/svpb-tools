import Fluent

struct CreateBinderDefinition: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(BinderDefinition.schema)
            .id()
            .field("branch_name", .string, .required, .references(Branch.schema, "name"))
            .field("position", .int, .required)
            .field("name", .string, .required)
            .field("output", .string, .required)
            // JSON-encoded [OfficialBinderSection] (TEXT column; serialised via Codable).
            .field("sections", .string, .required)
            .field("created_at", .datetime)
            // Two binders writing the same file would overwrite each other.
            .unique(on: "branch_name", "output")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BinderDefinition.schema).delete()
    }
}
