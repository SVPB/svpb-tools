import Vapor
import Crypto

/// Handles `POST /webhook/github`.
///
/// Validates the HMAC-SHA256 signature supplied by GitHub, then queues a
/// build for the affected branch.  In Phase 0 the build step is stubbed;
/// the full implementation is in Phase 1.
struct WebhookController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("webhook", "github", use: githubWebhook)
    }

    @Sendable
    func githubWebhook(_ req: Request) async throws -> Response {
        // ── Signature validation ──────────────────────────────────────────
        guard let signatureHeader = req.headers.first(name: "X-Hub-Signature-256") else {
            throw Abort(.unauthorized, reason: "Missing X-Hub-Signature-256 header.")
        }

        let secret = Environment.get("GITHUB_WEBHOOK_SECRET") ?? ""
        guard let bodyBuffer = req.body.data else {
            throw Abort(.badRequest, reason: "Empty request body.")
        }
        let bodyBytes = Data(buffer: bodyBuffer)

        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: bodyBytes, using: key)
        let expectedSignature = "sha256=" + mac.map { String(format: "%02x", $0) }.joined()

        guard signatureHeader == expectedSignature else {
            throw Abort(.unauthorized, reason: "Invalid signature.")
        }

        // ── Event routing ─────────────────────────────────────────────────
        let eventType = req.headers.first(name: "X-GitHub-Event") ?? ""
        guard eventType == "push" else {
            // Acknowledge non-push events without acting on them.
            return Response(status: .ok)
        }

        // ── Parse push payload ────────────────────────────────────────────
        let payload = try req.content.decode(GitHubPushPayload.self)
        let branch = payload.branchName

        req.logger.info("Push event received for branch '\(branch)' at \(payload.headCommit.id).")

        // Fire the build in the background; return 202 immediately.
        let db = req.db
        let logger = req.logger
        let commitSha = payload.headCommit.id
        let buildService = req.application.buildService
        Task {
            await buildService.runBuild(
                branch: branch, commitSha: commitSha, db: db, logger: logger)
        }

        return Response(status: .accepted)
    }
}

// MARK: - GitHub push payload (minimal — only the fields TNG uses)

/// The fields TNG reads from a GitHub push event payload.
/// All other fields sent by GitHub are ignored.
private struct GitHubPushPayload: Decodable {
    /// Full ref, e.g. `refs/heads/2026`.
    let ref: String
    let headCommit: HeadCommit

    /// The branch name extracted from `ref`.
    var branchName: String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    struct HeadCommit: Decodable {
        let id: String
    }

    enum CodingKeys: String, CodingKey {
        case ref
        case headCommit = "head_commit"
    }
}
