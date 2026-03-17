import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Vapor

// MARK: - SlackService

/// Sends messages to Slack via two channels:
///
/// 1. **`chat.postMessage`** — direct messages to a specific Slack user (used for
///    sending magic-link login tokens).
/// 2. **Incoming Webhook** — posts build notifications to the configured channel.
actor SlackService {

    private let botToken: String
    private let webhookURL: String
    private let httpClient: HTTPClient
    private let logger: Logger

    init(
        botToken: String,
        webhookURL: String,
        httpClient: HTTPClient,
        logger: Logger
    ) {
        self.botToken = botToken
        self.webhookURL = webhookURL
        self.httpClient = httpClient
        self.logger = logger
    }

    // MARK: - Public API

    /// Sends a direct message to a Slack user via `chat.postMessage`.
    ///
    /// Used to deliver magic-link login URLs.
    func sendDM(to slackUserId: String, text: String) async throws {
        struct PostMessageBody: Encodable {
            let channel: String
            let text: String
        }
        let body = PostMessageBody(channel: slackUserId, text: text)
        try await postJSON(
            to: "https://slack.com/api/chat.postMessage",
            body: body,
            authorizationHeader: "Bearer \(botToken)"
        )
        logger.info("[Slack] DM sent to \(slackUserId)")
    }

    /// Posts a build notification to the configured channel via Incoming Webhook.
    func postBuildNotification(branch: String, status: BuildStatus, files: [String]) async throws {
        let emoji = status == .success ? "✅" : "❌"
        let fileList = files.isEmpty
            ? "_(no files)_"
            : files.map { "• \($0)" }.joined(separator: "\n")
        let text = "\(emoji) *Build \(status.rawValue)* — branch `\(branch)`\n\(fileList)"

        struct WebhookBody: Encodable {
            let text: String
        }
        try await postJSON(
            to: webhookURL,
            body: WebhookBody(text: text),
            authorizationHeader: nil
        )
        logger.info("[Slack] Notification posted for branch '\(branch)' (\(status.rawValue))")
    }

    // MARK: - Private helpers

    private func postJSON<T: Encodable>(
        to urlString: String,
        body: T,
        authorizationHeader: String?
    ) async throws {
        let bodyData = try JSONEncoder().encode(body)

        var request = HTTPClientRequest(url: urlString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        if let auth = authorizationHeader {
            request.headers.add(name: "Authorization", value: auth)
        }
        request.body = .bytes(ByteBuffer(bytes: bodyData))

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard response.status.code >= 200 && response.status.code < 300 else {
            logger.warning("[Slack] HTTP \(response.status.code) from \(urlString)")
            throw ServiceError.unexpectedResponseCode("\(response.status.code)")
        }
    }
}
