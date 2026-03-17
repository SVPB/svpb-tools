import AsyncHTTPClient
import Foundation
import NIOCore
import Vapor

// MARK: - BoxAuthCommand

/// Interactive Box OAuth2 authorisation helper.
///
/// Usage (from the `docker compose run` context described in the README):
///
///     swift run TNG box-auth
///
/// The command:
///
/// 1. Prints a Box authorisation URL.
/// 2. Starts a temporary HTTP server on port 8080.
/// 3. Waits for Box to redirect the user's browser to `/box-callback?code=…`.
/// 4. Exchanges the authorisation code for an access token + refresh token.
/// 5. Prints the refresh token — copy it into `BOX_REFRESH_TOKEN` in `.env`.
/// 6. Shuts down the server and exits.
struct BoxAuthCommand: AsyncCommand {

    static let name = "box-auth"

    struct Signature: CommandSignature {
        @Option(name: "hostname", short: "H", help: "Hostname to bind (default: 0.0.0.0)")
        var hostname: String?

        @Option(name: "port", short: "p", help: "Port to bind (default: 8080)")
        var port: Int?

        @Option(
            name: "redirect-base-url",
            help: """
            Public base URL that Box will redirect to after authorisation, e.g. \
            https://my-tunnel.ngrok-free.app. \
            Use this when the server is reachable externally at a different address than \
            localhost (for example when running inside Docker with an ngrok tunnel). \
            The path /box-callback is appended automatically. \
            Defaults to http://localhost:<port>.
            """
        )
        var redirectBaseURL: String?
    }

    var help: String {
        "Run the Box OAuth2 authorisation flow to obtain an initial refresh token."
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application

        // ── Validate credentials ───────────────────────────────────────────
        let clientID     = Environment.get("BOX_CLIENT_ID")     ?? ""
        let clientSecret = Environment.get("BOX_CLIENT_SECRET") ?? ""

        guard !clientID.isEmpty else {
            context.console.error("BOX_CLIENT_ID is not set. Add it to your .env file.")
            return
        }
        guard !clientSecret.isEmpty else {
            context.console.error("BOX_CLIENT_SECRET is not set. Add it to your .env file.")
            return
        }

        // ── Build redirect URI ─────────────────────────────────────────────
        let hostname = signature.hostname ?? "0.0.0.0"
        let port     = signature.port ?? 8080
        let baseURL  = signature.redirectBaseURL.map { $0.trimmingCharacters(in: .init(charactersIn: "/")) }
                       ?? "http://localhost:\(port)"
        let redirectURI = "\(baseURL)/box-callback"

        // ── Shared state between the HTTP callback and this wait loop ──────
        let receiver = BoxAuthCodeReceiver()

        // Register /box-callback route before starting the server
        app.get("box-callback") { req async throws -> Response in
            guard let code = req.query[String.self, at: "code"] else {
                let body = "<h1>Missing code parameter.</h1>"
                return Response(status: .badRequest,
                                headers: ["Content-Type": "text/html"],
                                body: .init(string: body))
            }
            let error = req.query[String.self, at: "error"]
            if let err = error {
                await receiver.fail(message: err)
                let body = "<h1>Box returned an error: \(err)</h1><p>Check the terminal.</p>"
                return Response(status: .badRequest,
                                headers: ["Content-Type": "text/html"],
                                body: .init(string: body))
            }
            await receiver.succeed(code: code)
            let body = """
            <h1>Authorisation complete!</h1>
            <p>Return to the terminal — your refresh token has been printed there.</p>
            <p>You can close this browser tab.</p>
            """
            return Response(status: .ok,
                            headers: ["Content-Type": "text/html"],
                            body: .init(string: body))
        }

        // ── Print the authorisation URL ────────────────────────────────────
        let state = UUID().uuidString
        var comps  = URLComponents(string: "https://account.box.com/api/oauth2/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",     value: clientID),
            URLQueryItem(name: "redirect_uri",  value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state",         value: state),
        ]
        let authURL = comps.url!.absoluteString

        context.console.print("")
        context.console.print("┌─────────────────────────────────────────────────┐")
        context.console.print("│  Box OAuth2 — one-time authorisation             │")
        context.console.print("└─────────────────────────────────────────────────┘")
        context.console.print("")
        context.console.print("Open this URL in your browser:")
        context.console.print("")
        context.console.print("  \(authURL)")
        context.console.print("")
        context.console.print("Log in as the Box user who owns the pipe_music folder,")
        context.console.print("then click Grant Access.")
        context.console.print("")
        context.console.print("Waiting for callback on \(redirectURI) …")
        context.console.print("")

        // ── Start the server ───────────────────────────────────────────────
        try await app.server.start(address: .hostname(hostname, port: port))

        // ── Wait for the auth code ─────────────────────────────────────────
        let code: String
        do {
            code = try await receiver.waitForCode()
        } catch {
            await app.server.shutdown()
            context.console.error("Authorisation failed: \(error)")
            return
        }
        await app.server.shutdown()

        // ── Exchange the code for tokens ───────────────────────────────────
        context.console.print("Received authorisation code. Exchanging for tokens…")

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup))
        let refreshToken: String
        do {
            refreshToken = try await exchangeCodeForRefreshToken(
                code: code,
                redirectURI: redirectURI,
                clientID: clientID,
                clientSecret: clientSecret,
                httpClient: httpClient,
                logger: app.logger
            )
            try await httpClient.shutdown()
        } catch {
            try? await httpClient.shutdown()
            context.console.error("Token exchange failed: \(error)")
            return
        }

        // ── Print the result ───────────────────────────────────────────────
        context.console.print("")
        context.console.print("┌─────────────────────────────────────────────────┐")
        context.console.print("│  Success! Copy this value into your .env file.   │")
        context.console.print("└─────────────────────────────────────────────────┘")
        context.console.print("")
        context.console.print("BOX_REFRESH_TOKEN=\(refreshToken)")
        context.console.print("")
        context.console.print("Box refresh tokens are valid for 60 days of inactivity.")
        context.console.print("TNG rotates the token automatically during normal operation.")
        context.console.print("")
    }

    // MARK: - Token exchange

    private struct TokenResponse: Decodable {
        let accessToken:  String
        let refreshToken: String
        let expiresIn:    Int

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
        }
    }

    private func exchangeCodeForRefreshToken(
        code: String,
        redirectURI: String,
        clientID: String,
        clientSecret: String,
        httpClient: HTTPClient,
        logger: Logger
    ) async throws -> String {
        var request = HTTPClientRequest(url: "https://api.box.com/oauth2/token")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")

        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "client_id=\(clientID)",
            "client_secret=\(clientSecret)",
            "redirect_uri=\(redirectURI)",
        ].joined(separator: "&")

        request.body = .bytes(ByteBuffer(string: body))

        let response = try await httpClient.execute(request, timeout: .seconds(30))
        let responseBody = try await response.body.collect(upTo: 1024 * 1024)

        guard response.status == .ok else {
            let text = String(buffer: responseBody)
            logger.error("[box-auth] Token exchange failed (\(response.status)): \(text)")
            throw BoxAuthError.tokenExchangeFailed(status: response.status.code, body: text)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: Data(buffer: responseBody))
        return decoded.refreshToken
    }
}

// MARK: - BoxAuthCodeReceiver

/// Coordinates the auth code between the /box-callback HTTP handler and the
/// command's async wait. Uses a `CheckedContinuation` via an actor to avoid
/// data races.
private actor BoxAuthCodeReceiver {

    private var continuation: CheckedContinuation<String, Error>?

    func succeed(code: String) {
        continuation?.resume(returning: code)
        continuation = nil
    }

    func fail(message: String) {
        continuation?.resume(throwing: BoxAuthError.boxReturnedError(message))
        continuation = nil
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
        }
    }
}

// MARK: - BoxAuthError

enum BoxAuthError: Error, CustomStringConvertible {
    case tokenExchangeFailed(status: UInt, body: String)
    case boxReturnedError(String)

    var description: String {
        switch self {
        case .tokenExchangeFailed(let status, let body):
            return "HTTP \(status) from Box token endpoint: \(body)"
        case .boxReturnedError(let msg):
            return "Box returned an error: \(msg)"
        }
    }
}
