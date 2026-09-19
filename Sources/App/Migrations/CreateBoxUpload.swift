import Fluent

struct CreateBoxUpload: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(BoxUpload.schema)
            .id()
            .field("branch_name", .string, .required, .references(Branch.schema, "name"))
            .field("filename", .string, .required)
            .field("local_path", .string, .required)
            .field("content_hash", .string, .required)
            .field("uploaded_at", .datetime)
            .field("last_error", .string)
            .field("attempts", .int, .required)
            // One row per binder per branch: the record of that file's journey to Box,
            // not a log of attempts.
            .unique(on: "branch_name", "filename")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BoxUpload.schema).delete()
    }
}
