import Fluent

struct CreateBranch: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(Branch.schema)
            // Primary key: the branch name (git branch = year proxy, e.g. "2026")
            .field("name", .string, .identifier(auto: false))
            .field("last_built", .datetime)
            .field("head_sha", .string)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Branch.schema).delete()
    }
}
