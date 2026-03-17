import Fluent
import Vapor

/// A TNG user, identified by their Slack user ID.
///
/// Users are created by an admin via `POST /admin/users`, or bootstrapped from
/// `INITIAL_ADMIN_SLACK_USER_ID` on first startup.  Authentication is performed
/// via Slack magic-link (`LoginToken`), not passwords.
public final class User: Model, @unchecked Sendable {

    public static let schema = "users"

    // MARK: - Fields

    @ID(key: .id)
    public var id: UUID?

    /// Slack user ID, e.g. "U012AB3CD".  Unique across all users.
    @Field(key: "slack_user_id")
    public var slackUserId: String

    /// Slack display name captured at the time of last login.  May be nil for
    /// users who have never logged in.
    @OptionalField(key: "display_name")
    public var displayName: String?

    /// Permission level.
    @Field(key: "role")
    public var role: UserRole

    /// Set automatically when the record is created.
    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    /// Updated by the authentication flow each time a magic-link is redeemed.
    @OptionalField(key: "last_login_at")
    public var lastLoginAt: Date?

    // MARK: - Lifecycle

    public init() {}

    init(
        id: UUID? = nil,
        slackUserId: String,
        displayName: String? = nil,
        role: UserRole = .member
    ) {
        self.id = id
        self.slackUserId = slackUserId
        self.displayName = displayName
        self.role = role
    }
}
