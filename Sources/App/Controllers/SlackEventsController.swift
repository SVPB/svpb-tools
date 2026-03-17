import Crypto
import Fluent
import Vapor

/// Handles `POST /slack/events`.
///
/// Responsibilities:
///   1. Validate the Slack request signature (HMAC-SHA256 with `SLACK_SIGNING_SECRET`).
///   2. Respond to the `url_verification` challenge during app setup.
///   3. Dispatch `message.im` events: look up (or create) the sender's `User`
///      record, generate a single-use `LoginToken`, and reply with a DM
///      containing the magic-link URL.
struct SlackEventsController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        routes.post("slack", "events", use: handle)
    }

    @Sendable
    func handle(_ req: Request) async throws -> Response {
        // ── Signature validation ────────────────────────────────────────────
        try verifySlackSignature(req)

        // ── Parse outer envelope ────────────────────────────────────────────
        let envelope = try req.content.decode(SlackEventEnvelope.self)

        switch envelope.type {

        case "url_verification":
            // Slack sends this when the Events API URL is first configured.
            guard let challenge = envelope.challenge else {
                throw Abort(.badRequest, reason: "url_verification missing challenge field.")
            }
            return Response(
                status: .ok,
                headers: ["Content-Type": "text/plain"],
                body: .init(string: challenge)
            )

        case "event_callback":
            guard let event = envelope.event else {
                return Response(status: .ok)
            }
            // Only act on direct messages; ignore bot messages.
            if event.type == "message", event.channelType == "im",
               event.botId == nil, let slackUserId = event.user {
                req.logger.info("[Slack] DM from \(slackUserId) — generating login token")
                // Fire and forget; the HTTP response must be ≤3 s per Slack's rules.
                let app = req.application
                Task {
                    await handleLoginRequest(slackUserId: slackUserId, app: app)
                }
            }
            return Response(status: .ok)

        default:
            return Response(status: .ok)
        }
    }

    // MARK: - Login token flow

    private func handleLoginRequest(slackUserId: String, app: Application) async {
        let db = app.db
        let logger = app.logger

        do {
            // Ensure the user exists in our database.
            guard (try await User.query(on: db)
                .filter(\.$slackUserId == slackUserId)
                .first()) != nil
            else {
                // Unknown user — silently ignore (prevents user enumeration).
                logger.info("[Slack] Unknown user \(slackUserId) — not in user table")
                return
            }

            // Generate a single-use token valid for 10 minutes.
            let token = LoginToken(
                slackUserId: slackUserId,
                expiresAt: Date().addingTimeInterval(10 * 60)
            )
            try await token.save(on: db)

            let tokenId = try token.requireID()
            let domain = Environment.get("DOMAIN") ?? "localhost:8080"
            let loginURL = "https://\(domain)/auth/token/\(tokenId)"

            // Send the login link via DM.
            try await app.slackService.sendDM(
                to: slackUserId,
                text: "Here is your TNG login link (valid 10 minutes):\n\(loginURL)"
            )
            logger.info("[Slack] Login link sent to \(slackUserId) — token \(tokenId)")

        } catch {
            logger.error("[Slack] Failed to generate login token for \(slackUserId): \(error)")
        }
    }

    // MARK: - Signature verification

    /// Verifies the `X-Slack-Signature` header using HMAC-SHA256.
    ///
    /// Reference: https://api.slack.com/authentication/verifying-requests-from-slack
    private func verifySlackSignature(_ req: Request) throws {
        guard let signatureHeader = req.headers.first(name: "X-Slack-Signature"),
              let timestampHeader = req.headers.first(name: "X-Slack-Request-Timestamp"),
              let timestamp = Double(timestampHeader)
        else {
            throw Abort(.unauthorized, reason: "Missing Slack signature headers.")
        }

        // Reject replayed requests older than 5 minutes.
        guard abs(Date().timeIntervalSince1970 - timestamp) < 300 else {
            throw Abort(.unauthorized, reason: "Slack request timestamp is too old.")
        }

        guard let bodyBuffer = req.body.data else {
            throw Abort(.badRequest, reason: "Empty request body.")
        }
        let bodyString = String(buffer: bodyBuffer)
        let sigBaseString = "v0:\(timestampHeader):\(bodyString)"

        let secret = Environment.get("SLACK_SIGNING_SECRET") ?? ""
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(sigBaseString.utf8), using: key)
        let expected = "v0=" + mac.map { String(format: "%02x", $0) }.joined()

        guard signatureHeader == expected else {
            throw Abort(.unauthorized, reason: "Invalid Slack signature.")
        }
    }
}

// MARK: - Decodable event types

private struct SlackEventEnvelope: Decodable {
    let type: String
    let challenge: String?
    let event: SlackEvent?
}

private struct SlackEvent: Decodable {
    let type: String
    let user: String?
    let channelType: String?
    let botId: String?

    enum CodingKeys: String, CodingKey {
        case type, user
        case channelType = "channel_type"
        case botId = "bot_id"
    }
}
