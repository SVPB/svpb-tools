import Fluent
import Vapor

/// A record of a single build job triggered by a GitHub push event.
///
/// `status` transitions:  running → success | failure
/// `files` is a JSON-encoded list of output PDF filenames; Fluent serialises it
/// automatically via `Codable` when stored as a TEXT column in SQLite.
final class Build: Model, @unchecked Sendable {

    static let schema = "builds"

    // MARK: - Fields

    @ID(key: .id)
    var id: UUID?

    /// FK → Branch.name.
    @Parent(key: "branch_name")
    var branch: Branch

    /// Set automatically when the record is created (i.e. when the build starts).
    @Timestamp(key: "triggered", on: .create)
    var triggered: Date?

    /// Git commit SHA that triggered this build.  May be nil if the webhook
    /// payload did not include a head_commit.
    @OptionalField(key: "commit_sha")
    var commitSha: String?

    /// Current lifecycle state.
    @Field(key: "status")
    var status: BuildStatus

    /// Full stdout/stderr captured from CeolKit and the build pipeline.
    /// Available in the admin UI for diagnosing failures.
    @OptionalField(key: "log")
    var log: String?

    /// Filenames of the PDFs produced by this build.
    /// Stored as a JSON array in a TEXT column, e.g. `["Amazing Grace.pdf","Scotland the Brave.pdf"]`.
    @Field(key: "files")
    var files: [String]

    // MARK: - Lifecycle

    init() {}

    init(
        id: UUID? = nil,
        branch: Branch,
        commitSha: String? = nil,
        status: BuildStatus = .running,
        log: String? = nil,
        files: [String] = []
    ) throws {
        self.id = id
        self.$branch.id = try branch.requireID()
        self.commitSha = commitSha
        self.status = status
        self.log = log
        self.files = files
    }
}
