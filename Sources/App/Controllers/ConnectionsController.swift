import Fluent
import Vapor

// MARK: - ConnectionsController

/// The admin connections page, and the authorisation flow that runs from it for a
/// destination that can be authorised (#86).
///
/// Routes:
///   - `GET  /admin/connections`                       — status of every remote service
///   - `GET  /admin/connections/destination/authorize` — opens the destination's consent
///                                                       screen (popup)
///   - `GET  <callbackPath>`                           — where the provider sends the
///                                                       browser back: `/box-callback` for Box
///
/// The two authorisation routes exist only when the destination in use is an
/// `AuthorizableDestination`. The callback is at whatever path the destination declares,
/// because that address is registered in the provider's console.
///
/// The callback is deliberately outside the `/admin` group. `AdminAuthMiddleware`
/// redirects an unauthenticated request to the login page, which would swallow the
/// authorisation code and leave the operator staring at a login form with no idea that
/// the grant they just made had been thrown away. It checks the session itself and says
/// what went wrong instead.
struct ConnectionsController: RouteCollection {

    /// The destination the authorisation routes drive, if it can be authorised.
    let destination: (any AuthorizableDestination)?

    /// Session key holding the `state` value of an authorisation in flight.
    static let stateSessionKey = "destinationAuthState"

    /// Where a destination's Authorise button points.
    static let authorizePath = "/admin/connections/destination/authorize"

    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped(AdminAuthMiddleware())
        admin.get("admin", "connections", use: page)

        guard let destination else { return }
        admin.get(Self.pathComponents(Self.authorizePath), use: authorize)
        routes.get(Self.pathComponents(destination.callbackPath), use: callback)
    }

    private static func pathComponents(_ path: String) -> [PathComponent] {
        path.split(separator: "/").map { .constant(String($0)) }
    }

    // MARK: - The page

    @Sendable
    func page(_ req: Request) async throws -> View {
        struct Context: Encodable {
            let appVersion: String
            let isAdmin: Bool
            let currentUser: String
            let connections: [ConnectionStatus]
            /// The destination's callback address, for the panel that says what to
            /// register in its console; absent when it cannot be authorised.
            let redirectURI: String?
            let destinationName: String
        }

        return try await req.view.render("admin/connections", Context(
            appVersion: AppVersion.current,
            isAdmin: true,
            currentUser: req.authenticatedUser?.displayName ?? req.authenticatedUser?.slackUserId ?? "",
            connections: await ConnectionsReport.gather(on: req.application),
            redirectURI: destination.map { Self.redirectURI(for: req, callbackPath: $0.callbackPath) },
            destinationName: req.application.artifactDestination.displayName
        ))
    }

    // MARK: - Authorisation

    /// Sends the browser to the destination's consent screen.
    @Sendable
    func authorize(_ req: Request) async throws -> Response {
        guard let destination else { throw Abort(.notFound) }
        let state = UUID().uuidString
        req.session.data[Self.stateSessionKey] = state

        let url = await destination.authorizationURL(
            redirectURI: Self.redirectURI(for: req, callbackPath: destination.callbackPath),
            state: state)
        req.logger.info("[\(destination.displayName)] Starting authorisation for \(req.authenticatedUser?.slackUserId ?? "?")")
        return req.redirect(to: url)
    }

    /// Where the provider sends the browser back, with an authorisation code to exchange.
    ///
    /// Renders a page rather than redirecting: this runs in a popup, and what it does on
    /// success is refresh the window that opened it and close itself.
    @Sendable
    func callback(_ req: Request) async throws -> View {
        guard let destination else { throw Abort(.notFound) }
        let name = destination.displayName

        func render(_ error: String?) async throws -> View {
            struct Context: Encodable {
                let appVersion: String
                let destinationName: String
                let error: String?
            }
            return try await req.view.render(
                "admin/authorization-result",
                Context(appVersion: AppVersion.current, destinationName: name, error: error))
        }

        // OAuth providers report a refusal by redirecting here with `error` instead of
        // `code`.
        if let refusal = req.query[String.self, at: "error"] {
            let description = req.query[String.self, at: "error_description"] ?? refusal
            req.logger.warning("[\(name)] Authorisation refused: \(description)")
            return try await render("\(name) did not grant access: \(description)")
        }

        // The state is checked before anything else is read: without it, a link sent to a
        // signed-in admin could drive a token exchange of someone else's choosing.
        let expected = req.session.data[Self.stateSessionKey]
        req.session.data[Self.stateSessionKey] = nil
        guard let expected, let state = req.query[String.self, at: "state"], state == expected else {
            req.logger.warning("[\(name)] Authorisation callback with a bad or missing state")
            return try await render(
                "This authorisation did not start here, or it started in another browser "
                + "session. Open the connections page and press Re-authorise again.")
        }

        guard await req.isAdminSession() else {
            return try await render("Your session has expired. Sign in again, then retry.")
        }

        guard let code = req.query[String.self, at: "code"] else {
            return try await render("\(name) sent no authorisation code.")
        }

        do {
            try await destination.adoptAuthorizationCode(
                code, redirectURI: Self.redirectURI(for: req, callbackPath: destination.callbackPath))
        } catch {
            req.logger.error("[\(name)] Authorisation failed: \(error)")
            return try await render("\(error)")
        }
        // The channel may have been told the destination is failing; this is the fix, so
        // say so now rather than at the next scheduled renewal.
        await DestinationKeepAlive.record(
            failure: nil, reason: .reauthorised, for: destination, app: req.application)
        return try await render(nil)
    }

    // MARK: - Redirect URI

    /// The address the provider sends the browser back to: `callbackPath` on this server.
    ///
    /// The provider matches this against the URIs registered for the application, and
    /// matches it *again* against the one presented at the exchange — so both ends have
    /// to derive it the same way, which is why this is one function and not two string
    /// literals.
    ///
    /// `DOMAIN` is what Caddy already serves TNG on, which makes it the address the
    /// provider has to be told about. Falling back to the request's own host keeps local
    /// development working, where the tunnel or `localhost:8080` is the whole story.
    static func redirectURI(for req: Request, callbackPath: String) -> String {
        if let domain = Environment.get("DOMAIN")?.trimmingCharacters(in: .whitespaces),
           !domain.isEmpty {
            return "https://\(domain)\(callbackPath)"
        }
        let forwarded = req.headers.first(name: "X-Forwarded-Proto")
        let scheme = forwarded ?? "http"
        let host = req.headers.first(name: .host) ?? "localhost:8080"
        return "\(scheme)://\(host)\(callbackPath)"
    }
}
