import Fluent

struct CreateSetting: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(Setting.schema)
            // Primary key: the dotted setting name, e.g. "box.refresh_token".
            .field("key", .string, .identifier(auto: false))
            .field("value", .string, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Setting.schema).delete()
    }
}
