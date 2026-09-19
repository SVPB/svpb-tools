import Fluent
import Vapor

// MARK: - ConnectionsController

/// The admin connections page and the Box authorisation flow that runs from it.
///
/// Routes:
///   - `GET  /admin/connections`                  — status of every remote service
///   - `GET  /admin/connections/box/authorize`    — opens Box's consent screen (popup)
///   - `GET  /box-callback`                       — where Box sends the browser back
///
/// The callback is deliberately outside the `/admin` group. `AdminAuthMiddleware`
/// redirects an unauthenticated request to the login page, which would swallow the
/// authorisation code and leave the operator staring at a login form with no idea that
/// the grant they just made had been thrown away. It checks the session itself and says
/// what went wrong instead.
struct ConnectionsController: RouteCollection {

    /// Session key holding the `state` value of an authorisation in flight.
    static let stateSessionKey = "boxAuthState"

    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped(AdminAuthMiddleware())
        admin.get("admin", "connections", use: page)
        admin.get("admin", "connections", "box", "authorize", use: authorize)

        routes.get("box-callback", use: callback)
    }

    // MARK: - The page

    @Sendable
    func page(_ req: Request) async throws -> View {
        struct Context: Encodable {
            let appVersion: String
            let isAdmin: Bool
            let currentUser: String
            let connections: [ConnectionStatus]
            let redirectURI: String
        }

        return try await req.view.render("admin/connections", Context(
            appVersion: AppVersion.current,
            isAdmin: true,
            currentUser: req.authenticatedUser?.displayName ?? req.authenticatedUser?.slackUserId ?? "",
            connections: await ConnectionsReport.gather(on: req.application),
            redirectURI: Self.redirectURI(for: req)
        ))
    }

    // MARK: - Box authorisation

    /// Sends the browser to Box's consent screen.
    @Sendable
    func authorize(_ req: Request) async throws -> Response {
        let state = UUID().uuidString
        req.session.data[Self.stateSessionKey] = state

        let url = await req.application.boxService.authorizationURL(
            redirectURI: Self.redirectURI(for: req), state: state)
        req.logger.info("[Box] Starting authorisation for \(req.authenticatedUser?.slackUserId ?? "?")")
        return req.redirect(to: url)
    }

    /// Where Box sends the browser back, with an authorisation code to exchange.
    ///
    /// Renders a page rather than redirecting: this runs in a popup, and what it does on
    /// success is refresh the window that opened it and close itself.
    @Sendable
    func callback(_ req: Request) async throws -> View {
        func render(_ error: String?) async throws -> View {
            struct Context: Encodable {
                let appVersion: String
                let error: String?
            }
            return try await req.view.render(
                "admin/box-callback", Context(appVersion: AppVersion.current, error: error))
        }

        // Box reports a refusal by redirecting here with `error` instead of `code`.
        if let refusal = req.query[String.self, at: "error"] {
            let description = req.query[String.self, at: "error_description"] ?? refusal
            req.logger.warning("[Box] Authorisation refused: \(description)")
            return try await render("Box did not grant access: \(description)")
        }

        // The state is checked before anything else is read: without it, a link sent to a
        // signed-in admin could drive a token exchange of someone else's choosing.
        let expected = req.session.data[Self.stateSessionKey]
        req.session.data[Self.stateSessionKey] = nil
        guard let expected, let state = req.query[String.self, at: "state"], state == expected else {
            req.logger.warning("[Box] Authorisation callback with a bad or missing state")
            return try await render(
                "This authorisation did not start here, or it started in another browser "
                + "session. Open the connections page and press Re-authorise again.")
        }

        guard await req.isAdminSession() else {
            return try await render("Your session has expired. Sign in again, then retry.")
        }

        guard let code = req.query[String.self, at: "code"] else {
            return try await render("Box sent no authorisation code.")
        }

        do {
            try await req.application.boxService.adoptAuthorizationCode(
                code, redirectURI: Self.redirectURI(for: req))
        } catch {
            req.logger.error("[Box] Authorisation failed: \(error)")
            return try await render("\(error)")
        }
        return try await render(nil)
    }

    // MARK: - Redirect URI

    /// The address Box sends the browser back to.
    ///
    /// Box matches this against the URIs registered for the application, and matches it
    /// *again* against the one presented at the exchange — so both ends have to derive it
    /// the same way, which is why this is one function and not two string literals.
    ///
    /// `DOMAIN` is what Caddy already serves TNG on, which makes it the address Box has to
    /// be told about. Falling back to the request's own host keeps local development
    /// working, where the tunnel or `localhost:8080` is the whole story.
    static func redirectURI(for req: Request) -> String {
        if let domain = Environment.get("DOMAIN")?.trimmingCharacters(in: .whitespaces),
           !domain.isEmpty {
            return "https://\(domain)/box-callback"
        }
        let forwarded = req.headers.first(name: "X-Forwarded-Proto")
        let scheme = forwarded ?? "http"
        let host = req.headers.first(name: .host) ?? "localhost:8080"
        return "\(scheme)://\(host)/box-callback"
    }
}
