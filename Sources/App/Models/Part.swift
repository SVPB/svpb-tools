import Fluent
import Vapor

/// A single named part (voice) within a tune on a given branch.
///
/// Examples of part names: "Melody", "Harmony 1", "Harmony 2".
/// The composite natural key across the data model is
/// `(tune.branch_name, tune.slug, part.name)`.
final class Part: Model, @unchecked Sendable {

    static let schema = "parts"

    // MARK: - Fields

    @ID(key: .id)
    var id: UUID?

    /// FK → Tune.id.
    @Parent(key: "tune_id")
    var tune: Tune

    /// Display name for this part, e.g. "Melody" or "Harmony 1".
    @Field(key: "name")
    var name: String

    /// Path to the pre-built single-part PDF on disk, relative to the server's
    /// working directory.  Nil until the build pipeline has run for this part.
    @OptionalField(key: "pdf_path")
    var pdfPath: String?

    // MARK: - Lifecycle

    init() {}

    init(id: UUID? = nil, tune: Tune, name: String, pdfPath: String? = nil) throws {
        self.id = id
        self.$tune.id = try tune.requireID()
        self.name = name
        self.pdfPath = pdfPath
    }
}
