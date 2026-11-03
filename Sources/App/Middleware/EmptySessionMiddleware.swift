import Vapor

/// Discards a session that is still empty when the response is ready, so it is never stored.
///
/// Vapor's `SessionsMiddleware` stores every valid session, whatever its data
/// (vapor/vapor#3620). Two things hand it an empty one:
///
///   • Reading `req.session` on a request that brought no session creates one. The home
///     page, the binder pages and `AdminAuthMiddleware` all read it to ask who is signed in.
///   • A cookie naming no stored session makes `SessionsMiddleware` install an empty
///     session itself, before any route runs.
///
/// Either way a client that keeps no cookies, or sends made-up ones, would add a row to
/// `_fluent_sessions` with every request (#92). Destroying the empty session here sends
/// `SessionsMiddleware` down its "no valid session" branch instead: nothing is stored,
/// and if the request carried a cookie, that ID is deleted and the cookie is expired.
///
/// Must be registered immediately after `app.sessions.middleware`, so that it runs inside
/// it and its check happens before the session is saved.
///
/// No session TNG keeps is legitimately empty: sign-in writes `userId` and `userRole`,
/// and the Box authorisation writes its state into an admin's existing session. A
/// feature that needs a kept session has to put something in it.
struct EmptySessionMiddleware: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        if request.hasSession, request.session.data.snapshot.isEmpty {
            request.session.destroy()
        }
        return response
    }
}
