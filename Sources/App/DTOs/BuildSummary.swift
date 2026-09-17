import Vapor

/// A summary of a single build, used in list and health responses.
///
/// `status` uses the shared `BuildStatus` enum defined in `Models/BuildStatus.swift`
/// so that the Fluent model and this DTO stay in sync automatically.
public struct BuildSummary: Content {
    public let id: UUID
    public let branch: String
    public let triggered: Date
    public let commitSha: String?
    public let status: BuildStatus
    public let files: [String]

    enum CodingKeys: String, CodingKey {
        case id, branch, triggered, status, files
        case commitSha = "commit_sha"
    }
}
