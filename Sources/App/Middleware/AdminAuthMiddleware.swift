import Fluent
import Vapor

// MARK: - Session storage key

/// Typed request-storage key for the currently authenticated admin user.
struct AuthenticatedUserKey: StorageKey {
    typealias Value = User
}

extension Request {
    /// The authenticated admin user, set by `AdminAuthMiddleware`.
    var authenticatedUser: User? {
        get { storage[AuthenticatedUserKey.self] }
        set { storage[AuthenticatedUserKey.self] = newValue }
    }

    /// Returns the session user if one is present, regardless of role.
    /// Does not redirect — safe to call on unauthenticated routes.
    ///
    /// Checks `hasSession` first: reading `session` on a request without one would
    /// create an empty session just to find nothing in it (#92).
    func sessionUser() async -> User? {
        guard hasSession,
              let userIdString = session.data["userId"],
              let userId = UUID(uuidString: userIdString)
        else { return nil }
        return try? await User.find(userId, on: db)
    }

    /// Returns `true` if the current session belongs to an admin user.
    /// Does not redirect — safe to call on unauthenticated routes.
    func isAdminSession() async -> Bool {
        guard let user = await sessionUser() else { return false }
        return user.role == .admin
    }
}

// MARK: - AdminAuthMiddleware

/// Guards all `/admin/*` routes.
///
/// If the request carries a valid session with a known admin-role user,
/// the user is attached to `req.authenticatedUser` and the chain continues.
///
/// Otherwise:
///   • No session — redirect to `/admin/login`, the landing page that explains how to
///     get a Slack login link.
///   • A session whose user no longer exists — the session is destroyed, then the same
///     redirect.
///   • A signed-in member — `403 Forbidden`. Their session is kept: they are signed in,
///     just not allowed here, so neither signing them out nor telling them how to sign
///     in would be right (#91).
struct AdminAuthMiddleware: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Read user ID from the session, without creating one to read it from (#92).
        guard request.hasSession,
              let userIdString = request.session.data["userId"],
              let userId = UUID(uuidString: userIdString)
        else {
            return request.redirect(to: "/admin/login")
        }

        // Confirm the user still exists.
        guard let user = try await User.find(userId, on: request.db) else {
            // The session outlived its user — clear it.
            request.session.destroy()
            return request.redirect(to: "/admin/login")
        }

        // A member, or an admin since demoted, stays signed in but may not go further.
        guard user.role == .admin else {
            throw Abort(.forbidden, reason: "This page is for band administrators.")
        }

        request.authenticatedUser = user
        return try await next.respond(to: request)
    }
}
