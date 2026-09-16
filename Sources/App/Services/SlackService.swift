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
        struct WebhookBody: Encodable {
            let text: String
        }
        try await postJSON(
            to: webhookURL,
            body: WebhookBody(text: Self.buildNotificationText(branch: branch, status: status, files: files)),
            authorizationHeader: nil
        )
        logger.info("[Slack] Notification posted for branch '\(branch)' (\(status.rawValue))")
    }

    /// The message body for a build notification.
    ///
    /// A `partial` build must not read as a success: the channel is where band
    /// members without dashboard habits find out whether the new PDFs are real.
    static func buildNotificationText(branch: String, status: BuildStatus, files: [String]) -> String {
        let emoji: String
        switch status {
        case .success: emoji = "✅"
        case .partial: emoji = "⚠️"
        case .failure: emoji = "❌"
        case .running: emoji = "⏳"
        }
        var text = "\(emoji) *Build \(status.rawValue)* — branch `\(branch)`\n"
        if status == .partial {
            text += "_Some steps failed; see the build log on the admin dashboard._\n"
        }
        text += files.isEmpty
            ? "_(no files)_"
            : files.map { "• \($0)" }.joined(separator: "\n")
        return text
    }

    /// Fetches the display name for a Slack user via `users.info`.
    ///
    /// Returns the user's profile display name, falling back to their real name,
    /// then to nil if the API call fails or the fields are empty.
    /// Requires the `users:read` bot scope.
    func fetchDisplayName(for slackUserId: String) async -> String? {
        let url = "https://slack.com/api/users.info?user=\(slackUserId)"
        var request = HTTPClientRequest(url: url)
        request.method = .GET
        request.headers.add(name: "Authorization", value: "Bearer \(botToken)")

        struct UsersInfoResponse: Decodable {
            let ok: Bool
            let user: SlackUser?
            struct SlackUser: Decodable {
                let profile: Profile
                struct Profile: Decodable {
                    let displayName: String?
                    let realName: String?
                    enum CodingKeys: String, CodingKey {
                        case displayName = "display_name"
                        case realName    = "real_name"
                    }
                }
            }
        }

        do {
            let response = try await httpClient.execute(request, timeout: .seconds(10))
            let buffer = try await response.body.collect(upTo: 64 * 1024)
            let decoded = try JSONDecoder().decode(UsersInfoResponse.self, from: Data(buffer: buffer))
            guard decoded.ok, let profile = decoded.user?.profile else { return nil }
            let name = profile.displayName?.trimmingCharacters(in: .whitespaces)
            if let name, !name.isEmpty { return name }
            return profile.realName?.trimmingCharacters(in: .whitespaces)
        } catch {
            logger.warning("[Slack] Could not fetch display name for \(slackUserId): \(error)")
            return nil
        }
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
