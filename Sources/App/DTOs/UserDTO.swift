import Vapor

// MARK: - UserDTO

/// JSON representation of a TNG user, returned by user management endpoints.
public struct UserDTO: Content {
    public let id: UUID
    public let slackUserId: String
    public let displayName: String?
    public let role: UserRole
    public let createdAt: Date?
    public let lastLoginAt: Date?

    /// Initialise from a Fluent `User` model.
    public init(from user: User) throws {
        self.id = try user.requireID()
        self.slackUserId = user.slackUserId
        self.displayName = user.displayName
        self.role = user.role
        self.createdAt = user.createdAt
        self.lastLoginAt = user.lastLoginAt
    }

    enum CodingKeys: String, CodingKey {
        case id, role
        case slackUserId  = "slack_user_id"
        case displayName  = "display_name"
        case createdAt    = "created_at"
        case lastLoginAt  = "last_login_at"
    }
}

// MARK: - UserCreateRequest

/// Request body for `POST /admin/users`.
public struct UserCreateRequest: Content {
    public let slackUserId: String
    public let role: UserRole

    enum CodingKeys: String, CodingKey {
        case slackUserId = "slack_user_id"
        case role
    }
}

// MARK: - UserRoleUpdate

/// Request body for `PATCH /admin/users/{id}`.
public struct UserRoleUpdate: Content {
    public let role: UserRole
}
