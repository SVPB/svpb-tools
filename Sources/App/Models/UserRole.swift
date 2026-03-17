/// The permission level of a TNG user.
///
/// Stored as a TEXT column in SQLite via Fluent's Codable serialisation.
/// Used by both the `User` Fluent model and user-facing DTOs.
public enum UserRole: String, Codable, Sendable {
    /// Full access: admin dashboard, build triggers, user management.
    case admin
    /// Read-only access: tune catalogue and personalised binder generation.
    case member
}
