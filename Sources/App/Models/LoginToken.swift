import Fluent
import Vapor

/// A single-use magic-link token sent to a user via Slack DM.
///
/// The token's UUID is used directly in the redemption URL:
///   `GET /auth/token/{id}`
///
/// Tokens expire 10 minutes after creation.  `usedAt` is set to the current
/// time on first redemption; any subsequent redemption attempt is rejected.
final class LoginToken: Model, @unchecked Sendable {

    static let schema = "login_tokens"

    // MARK: - Fields

    /// The token itself — a random UUID, also the URL path component.
    @ID(key: .id)
    var id: UUID?

    /// Slack user ID this token was issued for.  Not a Fluent FK; the User
    /// record is looked up by Slack ID at redemption time.
    @Field(key: "slack_user_id")
    var slackUserId: String

    /// Hard expiry — tokens are invalid after this time regardless of `usedAt`.
    @Field(key: "expires_at")
    var expiresAt: Date

    /// Nil until the token is redeemed.  Non-nil means the token has been used
    /// and must be rejected on any further redemption attempt.
    @OptionalField(key: "used_at")
    var usedAt: Date?

    // MARK: - Lifecycle

    init() {}

    init(
        id: UUID? = nil,
        slackUserId: String,
        expiresAt: Date,
        usedAt: Date? = nil
    ) {
        self.id = id
        self.slackUserId = slackUserId
        self.expiresAt = expiresAt
        self.usedAt = usedAt
    }

    // MARK: - Helpers

    /// True if this token can still be redeemed.
    var isValid: Bool {
        usedAt == nil && expiresAt > Date()
    }
}
