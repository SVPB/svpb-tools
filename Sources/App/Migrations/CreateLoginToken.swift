import Fluent

struct CreateLoginToken: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(LoginToken.schema)
            // The UUID is also the magic-link URL token — no separate token column needed.
            .id()
            // Not a FK; User is looked up by Slack ID at redemption time.
            .field("slack_user_id", .string, .required)
            .field("expires_at", .datetime, .required)
            // Nil until redeemed.  Non-nil → already used; reject further redemptions.
            .field("used_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(LoginToken.schema).delete()
    }
}
