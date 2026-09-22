import Vapor

/// Response body for `GET /health`.
public struct HealthResponse: Content {
    public let status: Status
    public let version: String
    public let branches: [String]
    public let lastBuild: BuildSummary?
    /// The music repository the server is wired to, credentials stripped; `nil` when unset.
    ///
    /// `/health` is unauthenticated, and this is a deliberate exposure: the repository name
    /// is no secret to the band, and "which repository is this server reading?" is exactly
    /// the question an admin needs answered without first finding a login.
    public let musicRepo: String?

    public enum Status: String, Codable, Sendable {
        case ok
        case degraded
    }

    public init(
        status: Status,
        version: String = AppVersion.current,
        branches: [String] = [],
        lastBuild: BuildSummary? = nil,
        musicRepo: String? = nil
    ) {
        self.status = status
        self.version = version
        self.branches = branches
        self.lastBuild = lastBuild
        self.musicRepo = musicRepo
    }

    enum CodingKeys: String, CodingKey {
        case status, version, branches
        case lastBuild = "last_build"
        case musicRepo = "music_repo"
    }
}

/// Single source of truth for the server version string.
public enum AppVersion {
    public static let current = "0.4.0"
}
