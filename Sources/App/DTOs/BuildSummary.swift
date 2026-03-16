import Vapor

/// A summary of a single build, used in list and health responses.
/// Full definition (including log text) will be added in Phase 1.
public struct BuildSummary: Content {
    public let id: UUID
    public let branch: String
    public let triggered: Date
    public let commitSha: String?
    public let status: BuildStatus
    public let files: [String]

    public enum BuildStatus: String, Codable, Sendable {
        case running, success, failure
    }

    enum CodingKeys: String, CodingKey {
        case id, branch, triggered, status, files
        case commitSha = "commit_sha"
    }
}
