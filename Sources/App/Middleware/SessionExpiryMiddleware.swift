import Vapor

/// Enforces `SessionExpiry` on every request from a signed-in session (#93).
///
/// Before the handler runs, an expired session's data is cleared, so the request proceeds
/// as signed out: an admin URL redirects to `/admin/login`, and `/` shows the sign-in
/// card. `EmptySessionMiddleware` then deletes the row and expires the cookie (#92).
///
/// The session is emptied rather than destroyed so that redeeming a login link from a
/// browser whose old session has expired still works: `AuthController` writes the new
/// sign-in into the same session, which is then kept. A destroyed session would already
/// be marked invalid, and the new sign-in would be dropped without a word.
///
/// After the handler, a session that is signed in has `lastSeenAt` stamped with the
/// current time. Vapor rewrites the session row on every request anyway, so this adds no
/// writes. It never writes `signedInAt`: only a sign-in does, and a session without one is
/// expired.
///
/// Registered immediately after `app.sessions.middleware`, so that its stamps are in the
/// data that middleware stores.
struct SessionExpiryMiddleware: AsyncMiddleware {

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let policy = request.application.sessionExpiryPolicy
        let clock = request.application.sessionClock

        // Never read `session` on a request without one: that would create one (#92).
        if request.hasSession, request.session.data["userId"] != nil,
           SessionExpiry.isExpired(request.session.data, now: clock(), policy: policy) {
            request.logger.info("[Session] Signed-in session expired; signing it out")
            request.session.data = SessionData()
        }

        let response = try await next.respond(to: request)

        // Checked again: signing in from a browser with no session creates one.
        if request.hasSession, request.session.data["userId"] != nil {
            request.session.data[SessionExpiry.lastSeenAtKey] = SessionExpiry.stamp(clock())
        }
        return response
    }
}
