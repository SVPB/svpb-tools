import Fluent
import Vapor

/// A single tune within a branch (year).
///
/// The same tune slug may exist on multiple branches with different arrangements.
/// The composite natural key is `(branch_name, slug)`.
final class Tune: Model, @unchecked Sendable {

    static let schema = "tunes"

    // MARK: - Fields

    @ID(key: .id)
    var id: UUID?

    /// FK → Branch.name.  Identifies which year this arrangement belongs to.
    @Parent(key: "branch_name")
    var branch: Branch

    /// URL-safe identifier derived from the ABC filename, e.g. "archie_beag".
    /// Stable across years — the same physical tune keeps the same slug even when
    /// its arrangement changes.
    @Field(key: "slug")
    var slug: String

    /// Human-readable title from the ABC `T:` header field.
    @OptionalField(key: "title")
    var title: String?

    /// Path to the `.abc` source file within the repository, relative to the
    /// repo root, e.g. "tunes/highland/archie_beag.abc".
    @OptionalField(key: "abc_path")
    var abcPath: String?

    /// Automatically updated whenever the tune record is modified.
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    // MARK: - Relationships

    @Children(for: \.$tune)
    var parts: [Part]

    // MARK: - Lifecycle

    init() {}

    init(
        id: UUID? = nil,
        branch: Branch,
        slug: String,
        title: String? = nil,
        abcPath: String? = nil
    ) throws {
        self.id = id
        self.$branch.id = try branch.requireID()
        self.slug = slug
        self.title = title
        self.abcPath = abcPath
    }
}
