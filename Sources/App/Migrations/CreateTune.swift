import Fluent

struct CreateTune: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(Tune.schema)
            .id()
            .field("branch_name", .string, .required, .references(Branch.schema, "name"))
            .field("slug", .string, .required)
            .field("title", .string)
            .field("abc_path", .string)
            .field("updated_at", .datetime)
            // The same tune slug may appear in multiple years with different arrangements,
            // but within a single branch each slug must be unique.
            .unique(on: "branch_name", "slug")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Tune.schema).delete()
    }
}
