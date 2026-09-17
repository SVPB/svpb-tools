import Fluent
import Vapor

/// A single named part within a tune on a given branch.
///
/// Each part corresponds to one ABC voice (`V:`) found by CeolKit when the file
/// was rendered. The name is the voice's `nm=` attribute, falling back to `snm=`
/// and then to the raw voice ID, so `V:2 nm="Harmony 1"` becomes "Harmony 1" and
/// a bare `V:Bass` becomes "Bass". A file that declares no voices at all yields a
/// single part named "Full Score". See `CatalogueExtractor`.
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

    /// Ordered paths to the per-page SVG files for this part.
    /// Each entry is an absolute path to a `.svg` file on disk.
    /// Used by the binder assembly pipeline to re-render pages with a
    /// custom `startingPageNumber` offset via SVGPDFKit.
    /// Nil for Part records created before this column was added.
    @OptionalField(key: "svg_paths")
    var svgPaths: [String]?

    // MARK: - Lifecycle

    init() {}

    init(
        id: UUID? = nil,
        tune: Tune,
        name: String,
        pdfPath: String? = nil,
        svgPaths: [String]? = nil
    ) throws {
        self.id = id
        self.$tune.id = try tune.requireID()
        self.name = name
        self.pdfPath = pdfPath
        self.svgPaths = svgPaths
    }
}
