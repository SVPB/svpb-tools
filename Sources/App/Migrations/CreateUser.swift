import Fluent

struct CreateUser: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .id()
            .field("slack_user_id", .string, .required)
            .field("display_name", .string)
            // role stored as TEXT ("admin" | "member")
            .field("role", .string, .required)
            .field("created_at", .datetime)
            .field("last_login_at", .datetime)
            .unique(on: "slack_user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).delete()
    }
}
