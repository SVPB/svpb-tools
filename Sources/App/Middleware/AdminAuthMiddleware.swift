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
}

// MARK: - AdminAuthMiddleware

/// Guards all `/admin/*` routes.
///
/// If the request carries a valid session with a known admin-role user,
/// the user is attached to `req.authenticatedUser` and the chain continues.
///
/// Otherwise the request is redirected to `/admin/login` (the unauthenticated
/// landing page that explains how to get a Slack login link).
struct AdminAuthMiddleware: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Read user ID from the session.
        guard let userIdString = request.session.data["userId"],
              let userId = UUID(uuidString: userIdString)
        else {
            return request.redirect(to: "/admin/login")
        }

        // Confirm the user still exists and is still an admin.
        guard let user = try await User.find(userId, on: request.db),
              user.role == .admin
        else {
            // Session is stale or the user was demoted — clear it.
            request.session.destroy()
            return request.redirect(to: "/admin/login")
        }

        request.authenticatedUser = user
        return try await next.respond(to: request)
    }
}
