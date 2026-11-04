import Fluent

/// Creates the upload record under its original name, `box_uploads`.
///
/// History, so the table name is spelled out rather than taken from the model:
/// `RenameBoxUploads` renames it to `BinderUpload.schema` afterwards (#85).
struct CreateBoxUpload: AsyncMigration {

    static let schema = "box_uploads"

    func prepare(on database: any Database) async throws {
        try await database.schema(Self.schema)
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
        try await database.schema(Self.schema).delete()
    }
}
