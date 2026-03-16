import XCTest
import XCTVapor
import Crypto
@testable import App

final class WebhookTests: XCTestCase {

    var app: Application!
    let secret = "test-webhook-secret"

    override func setUp() async throws {
        setenv("GITHUB_WEBHOOK_SECRET", secret, 1)
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        unsetenv("GITHUB_WEBHOOK_SECRET")
    }

    // MARK: - Signature validation

    func testMissingSignatureHeaderReturnsUnauthorized() async throws {
        try await app.test(.POST, "webhook/github", beforeRequest: { req in
            req.headers.contentType = .json
            req.body = ByteBuffer(string: pushPayload(branch: "2026"))
        }) { res async in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testInvalidSignatureReturnsUnauthorized() async throws {
        try await app.test(.POST, "webhook/github", beforeRequest: { req in
            req.headers.contentType = .json
            req.headers.add(name: "X-Hub-Signature-256", value: "sha256=badhash")
            req.headers.add(name: "X-GitHub-Event", value: "push")
            req.body = ByteBuffer(string: pushPayload(branch: "2026"))
        }) { res async in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    // MARK: - Event routing

    func testNonPushEventReturnsOK() async throws {
        let body = pushPayload(branch: "2026")
        let sig = signature(for: body)
        try await app.test(.POST, "webhook/github", beforeRequest: { req in
            req.headers.contentType = .json
            req.headers.add(name: "X-Hub-Signature-256", value: sig)
            req.headers.add(name: "X-GitHub-Event", value: "ping")
            req.body = ByteBuffer(string: body)
        }) { res async in
            XCTAssertEqual(res.status, .ok)
        }
    }

    func testValidPushEventReturnsAccepted() async throws {
        let body = pushPayload(branch: "2026")
        let sig = signature(for: body)
        try await app.test(.POST, "webhook/github", beforeRequest: { req in
            req.headers.contentType = .json
            req.headers.add(name: "X-Hub-Signature-256", value: sig)
            req.headers.add(name: "X-GitHub-Event", value: "push")
            req.body = ByteBuffer(string: body)
        }) { res async in
            XCTAssertEqual(res.status, .accepted)
        }
    }

    // MARK: - Helpers

    /// Minimal GitHub push event payload.
    private func pushPayload(branch: String) -> String {
        """
        {
            "ref": "refs/heads/\(branch)",
            "head_commit": { "id": "abc123def456abc123def456abc123def456abc1" }
        }
        """
    }

    /// Computes the HMAC-SHA256 signature the way GitHub does.
    private func signature(for body: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
    }
}
