import Vapor

/// Response body for `GET /health`.
public struct HealthResponse: Content {
    public let status: Status
    public let version: String
    public let branches: [String]
    public let lastBuild: BuildSummary?

    public enum Status: String, Codable, Sendable {
        case ok
        case degraded
    }

    public init(
        status: Status,
        version: String = AppVersion.current,
        branches: [String] = [],
        lastBuild: BuildSummary? = nil
    ) {
        self.status = status
        self.version = version
        self.branches = branches
        self.lastBuild = lastBuild
    }

    enum CodingKeys: String, CodingKey {
        case status, version, branches
        case lastBuild = "last_build"
    }
}

/// Single source of truth for the server version string.
public enum AppVersion {
    public static let current = "0.1.0"
}
