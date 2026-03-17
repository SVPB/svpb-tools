import Fluent
import Vapor

/// Handles the magic-link token redemption flow.
///
/// `GET /auth/token/{token}` — the user clicks the URL from their Slack DM.
///
/// Validation:
///   • Token must exist in the database.
///   • Token must not be expired (`expires_at > now`).
///   • Token must not have already been used (`used_at` is nil).
///
/// On success:
///   • `used_at` is set to now (single-use enforcement).
///   • `last_login_at` on the `User` record is updated.
///   • A Vapor session is established (keyed by user UUID).
///   • The client is redirected to `/admin`.
struct AuthController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        routes.get("auth", "token", ":token", use: redeem)
    }

    @Sendable
    func redeem(_ req: Request) async throws -> Response {
        guard let tokenString = req.parameters.get("token"),
              let tokenUUID = UUID(uuidString: tokenString)
        else {
            throw Abort(.badRequest, reason: "Invalid token format.")
        }

        // Look up the token.
        guard let token = try await LoginToken.find(tokenUUID, on: req.db) else {
            return invalidTokenResponse(req)
        }

        // Validate.
        guard token.usedAt == nil else {
            return invalidTokenResponse(req, reason: "This login link has already been used.")
        }
        guard token.expiresAt > Date() else {
            return invalidTokenResponse(req, reason: "This login link has expired.")
        }

        // Look up the associated user.
        guard let user = try await User.query(on: req.db)
            .filter(\.$slackUserId == token.slackUserId)
            .first()
        else {
            return invalidTokenResponse(req, reason: "User account not found.")
        }

        // Mark the token as used.
        token.usedAt = Date()
        try await token.save(on: req.db)

        // Update last login timestamp.
        user.lastLoginAt = Date()
        try await user.save(on: req.db)

        // Establish session.
        let userId = try user.requireID()
        req.session.data["userId"] = userId.uuidString
        req.session.data["userRole"] = user.role.rawValue

        req.logger.info("[Auth] User \(user.slackUserId) (\(user.role.rawValue)) logged in via token \(tokenUUID)")

        return req.redirect(to: "/admin")
    }

    // MARK: - Helpers

    private func invalidTokenResponse(_ req: Request, reason: String = "Invalid or expired login link.") -> Response {
        // Return a minimal HTML page rather than a bare 401 so the user
        // understands what happened and knows to request a new link.
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="UTF-8"><title>Login Failed — TNG</title></head>
        <body>
          <h1>Login Failed</h1>
          <p>\(reason)</p>
          <p>Message <strong>@TNG</strong> in Slack to request a new login link.</p>
        </body>
        </html>
        """
        return Response(
            status: .unauthorized,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: .init(string: html)
        )
    }
}
