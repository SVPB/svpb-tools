import Fluent
import Vapor

/// The signed-in user's own account page (#90), open to any role.
///
///   `GET  /account`                            — the user's sign-in sessions
///   `POST /account/sessions/:sessionId/end`    — end one of them
///   `POST /account/sessions/end-others`        — end all but this browser's
///   `POST /account/sessions/end-all`           — end all, this browser's included
///
/// A session is named by its row's `id`, never its key, which is the cookie value. Ending
/// this browser's own session destroys it through `req.session`, so the sessions
/// middleware deletes the row and expires the cookie, exactly as **Sign out** does; any
/// other session's row is deleted directly.
struct AccountController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let account = routes.grouped(SignedInMiddleware()).grouped("account")
        account.get(use: page)
        account.post("sessions", ":sessionId", "end", use: endOne)
        account.post("sessions", "end-others", use: endOthers)
        account.post("sessions", "end-all", use: endAll)
    }

    // MARK: - Page

    struct SessionRow: Encodable {
        let id: String
        let device: String
        let userAgent: String
        let signedInISO: String
        let lastSeenISO: String
        let isCurrent: Bool
    }

    struct AccountContext: Encodable {
        let appVersion: String
        let isAdmin: Bool
        let currentUser: String
        let slackUserId: String
        let role: String
        let sessions: [SessionRow]
        let hasOthers: Bool
    }

    @Sendable
    func page(_ req: Request) async throws -> View {
        let user = try req.signedInUser
        let now = req.application.sessionClock()
        let currentKey = req.session.id
        let records = try await UserSessions.liveRecords(
            of: try user.requireID(), on: req.db, now: now,
            policy: req.application.sessionExpiryPolicy)

        let rows = try records.map { record in
            let isCurrent = record.key == currentKey
            // The stored row is as of this browser's previous request; this one is now.
            let data = isCurrent ? req.session.data : record.data
            let userAgent = data[UserSessions.userAgentKey]
            return SessionRow(
                id: try record.requireID().uuidString,
                device: UserSessions.deviceLabel(userAgent: userAgent),
                userAgent: userAgent ?? "",
                signedInISO: data[SessionExpiry.signedInAtKey] ?? "",
                lastSeenISO: isCurrent ? SessionExpiry.stamp(now) : (data[SessionExpiry.lastSeenAtKey] ?? ""),
                isCurrent: isCurrent
            )
        }
        // This browser first, then the rest by when they were last used.
        let ordered = rows.filter(\.isCurrent) + rows.filter { !$0.isCurrent }

        return try await req.view.render("account", AccountContext(
            appVersion: AppVersion.current,
            isAdmin: user.role == .admin,
            currentUser: user.displayName ?? user.slackUserId,
            slackUserId: user.slackUserId,
            role: user.role.rawValue,
            sessions: ordered,
            hasOthers: ordered.contains { !$0.isCurrent }
        ))
    }

    // MARK: - Ending sessions

    /// Ends one of the user's sessions. `404` for an ID that is not one of theirs, whether
    /// it exists or not. Ending this browser's own is signing out, and goes to `/`.
    @Sendable
    func endOne(_ req: Request) async throws -> Response {
        let user = try req.signedInUser
        guard let sessionId = req.parameters.get("sessionId").flatMap(UUID.init(uuidString:)),
              let record = try await UserSessions.record(sessionId, of: try user.requireID(), on: req.db)
        else {
            throw Abort(.notFound, reason: "No such session.")
        }

        if record.key == req.session.id {
            req.logger.info("[Account] \(user.slackUserId) ended this browser's session")
            req.session.destroy()
            return req.redirect(to: "/")
        }
        try await record.delete(on: req.db)
        req.logger.info("[Account] \(user.slackUserId) ended session \(sessionId)")
        return req.redirect(to: "/account")
    }

    /// Ends every session of the user's except this browser's.
    @Sendable
    func endOthers(_ req: Request) async throws -> Response {
        let user = try req.signedInUser
        let count = try await UserSessions.endAll(
            of: try user.requireID(), keeping: req.session.id, on: req.db)
        req.logger.info("[Account] \(user.slackUserId) ended \(count) other session(s)")
        return req.redirect(to: "/account")
    }

    /// Ends every session of the user's, this browser's included, and goes to `/`.
    @Sendable
    func endAll(_ req: Request) async throws -> Response {
        let user = try req.signedInUser
        let count = try await UserSessions.endAll(
            of: try user.requireID(), keeping: req.session.id, on: req.db)
        req.session.destroy()
        req.logger.info("[Account] \(user.slackUserId) signed out everywhere (\(count + 1) session(s))")
        return req.redirect(to: "/")
    }
}

extension Request {
    /// The user `SignedInMiddleware` attached; throws on a route it does not guard.
    var signedInUser: User {
        get throws {
            guard let user = authenticatedUser else { throw Abort(.unauthorized) }
            return user
        }
    }
}
