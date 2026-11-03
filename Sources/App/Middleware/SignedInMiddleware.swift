import Vapor

/// Guards the pages for any signed-in user, whatever their role, such as `/account` (#90).
///
/// A request whose session names an existing user has that user attached to
/// `req.authenticatedUser` and continues. Otherwise:
///   • No session, or one that signs nobody in — redirect to `/admin/login`, the page that
///     explains how to get a Slack login link.
///   • A session whose user no longer exists — the session is destroyed, then the same
///     redirect.
struct SignedInMiddleware: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Read the user ID without creating a session to read it from (#92).
        guard request.hasSession,
              let userIdString = request.session.data["userId"],
              let userId = UUID(uuidString: userIdString)
        else {
            return request.redirect(to: "/admin/login")
        }

        guard let user = try await User.find(userId, on: request.db) else {
            request.session.destroy()
            return request.redirect(to: "/admin/login")
        }

        request.authenticatedUser = user
        return try await next.respond(to: request)
    }
}
