import Vapor

/// Ends a signed-in session, whatever the user's role.
///
/// `POST /logout` — destroys the session and redirects to `/`.
///
/// It sits outside the `/admin` group so that a member can sign out as well as an admin,
/// and it needs no session at all: a session whose user has since been deleted is cleared
/// the same way, and signing out when already signed out is harmless (#91).
struct SessionController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        routes.post("logout", use: logout)
    }

    @Sendable
    func logout(_ req: Request) async throws -> Response {
        req.session.destroy()
        return req.redirect(to: "/")
    }
}
