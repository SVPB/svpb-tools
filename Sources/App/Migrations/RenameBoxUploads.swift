import Fluent
import SQLKit

/// Renames `box_uploads` to `binder_uploads` (#85).
///
/// Nothing in the record is specific to Box except its name, and it now records delivery
/// to whichever `ArtifactDestination` is in use. A rename rather than a copy, so the rows
/// — and with them any binder still waiting to be delivered — carry over untouched, along
/// with the table's unique index on `(branch_name, filename)`.
struct RenameBoxUploads: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await sql(database).alter(table: CreateBoxUpload.schema)
            .rename(to: BinderUpload.schema)
            .run()
    }

    func revert(on database: any Database) async throws {
        try await sql(database).alter(table: BinderUpload.schema)
            .rename(to: CreateBoxUpload.schema)
            .run()
    }

    /// Fluent's schema builder has no table rename; SQLKit's does, and SQLite runs it as
    /// `ALTER TABLE … RENAME TO …`.
    private func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else { throw NotSQL() }
        return sql
    }

    struct NotSQL: Error, CustomStringConvertible {
        var description: String { "Renaming box_uploads needs an SQL database" }
    }
}
