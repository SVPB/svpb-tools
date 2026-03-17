import Fluent

struct CreateBuild: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(Build.schema)
            .id()
            .field("branch_name", .string, .required, .references(Branch.schema, "name"))
            // Set by Fluent's @Timestamp(on: .create) when the Build record is inserted.
            .field("triggered", .datetime)
            .field("commit_sha", .string)
            // TEXT column; values are "running" | "success" | "failure"
            .field("status", .string, .required)
            // Full captured log; may be large.
            .field("log", .string)
            // JSON-encoded [String] of output PDF filenames.
            .field("files", .string, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Build.schema).delete()
    }
}
