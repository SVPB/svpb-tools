import Fluent
import Vapor

/// An official binder for one branch, as declared in that branch's `binders.yaml`.
///
/// The repository is the sole source of truth: every build replaces the branch's
/// definitions wholesale with whatever the file says, so these rows are a
/// queryable copy of the file, never edited in place.
final class BinderDefinition: Model, @unchecked Sendable {

    static let schema = "binder_definitions"

    // MARK: - Fields

    @ID(key: .id)
    var id: UUID?

    /// FK → Branch.name.  The branch whose `binders.yaml` declared this binder.
    @Parent(key: "branch_name")
    var branch: Branch

    /// Zero-based position of this binder in `binders.yaml`.
    @Field(key: "position")
    var position: Int

    /// Display name, e.g. "2026 Band Binder".
    @Field(key: "name")
    var name: String

    /// Output PDF filename, e.g. "2026_binder.pdf". Unique within a branch.
    @Field(key: "output")
    var output: String

    /// The ordered, titled sections, serialised as JSON.
    @Field(key: "sections")
    var sections: [OfficialBinderSection]

    /// Set when the build that read the file stored this row.
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    // MARK: - Lifecycle

    init() {}

    init(id: UUID? = nil, branch: String, position: Int, binder: OfficialBinder) {
        self.id = id
        self.$branch.id = branch
        self.position = position
        self.name = binder.name
        self.output = binder.output
        self.sections = binder.sections
    }
}
