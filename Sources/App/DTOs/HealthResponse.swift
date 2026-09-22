import Vapor

/// Response body for `GET /health`.
public struct HealthResponse: Content {
    public let status: Status
    public let version: String
    /// The full commit sha the image was built from; `nil` outside a CI-built image.
    public let commit: String?
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
        commit: String? = AppVersion.commit,
        branches: [String] = [],
        lastBuild: BuildSummary? = nil,
        musicRepo: String? = nil
    ) {
        self.status = status
        self.version = version
        self.commit = commit
        self.branches = branches
        self.lastBuild = lastBuild
        self.musicRepo = musicRepo
    }

    enum CodingKeys: String, CodingKey {
        case status, version, commit, branches
        case lastBuild = "last_build"
        case musicRepo = "music_repo"
    }
}

/// Single source of truth for the server version string.
public enum AppVersion {
    /// The release number, bumped by the release process.
    public static let release = "0.4.0"

    /// The commit the running image was built from (#65).
    ///
    /// CI passes `github.sha` into the image build, and the Dockerfile sets it as
    /// `TNG_GIT_COMMIT` in the runtime stage only, so the compiled binary is the same whatever
    /// commit it is labelled with. `nil` wherever the variable is unset — `swift run`, the test
    /// suite, a local `docker-compose.build.yml` build.
    public static let commit: String? = commit(from: ProcessInfo.processInfo.environment)

    /// `0.4.0+a3a6f58` in a CI-built image, the bare release everywhere else.
    public static let current = describe(release: release, commit: commit)

    /// The commit named by `TNG_GIT_COMMIT`, treating blank as absent.
    static func commit(from environment: [String: String]) -> String? {
        guard let value = environment["TNG_GIT_COMMIT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// The release with the short commit appended as semver build metadata.
    static func describe(release: String, commit: String?) -> String {
        guard let commit else { return release }
        return "\(release)+\(commit.prefix(7))"
    }
}
