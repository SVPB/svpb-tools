import Fluent
import Vapor

/// A git branch — used as a year proxy for tune arrangements (e.g. "2025", "2026").
///
/// The branch name is both the natural identifier and the primary key; UUIDs
/// are not used here because the name is the stable foreign key referenced
/// throughout the data model.
final class Branch: Model, @unchecked Sendable {

    static let schema = "branches"

    // MARK: - Fields

    /// The git branch name, e.g. "2026".  Acts as the primary key.
    @ID(custom: "name", generatedBy: .user)
    var id: String?

    /// Timestamp of the most recent successful build on this branch.
    @OptionalField(key: "last_built")
    var lastBuilt: Date?

    /// Commit SHA at the most recent successful build.
    @OptionalField(key: "head_sha")
    var headSha: String?

    // MARK: - Relationships

    @Children(for: \.$branch)
    var tunes: [Tune]

    @Children(for: \.$branch)
    var builds: [Build]

    // MARK: - Lifecycle

    init() {}

    init(name: String, lastBuilt: Date? = nil, headSha: String? = nil) {
        self.id = name
        self.lastBuilt = lastBuilt
        self.headSha = headSha
    }

    // MARK: - Convenience

    /// The branch name (alias for `id`).  Never nil once the model is saved.
    var name: String { id ?? "" }
}
