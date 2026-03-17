import Fluent
import Vapor

/// A request to generate a personalised binder PDF.
///
/// The `definition` column stores the full `BinderSpec` as JSON text.
/// `pdfPath` is nil until the generation pipeline completes; the client polls
/// `GET /binders/{id}` to check status.
final class BinderRequest: Model, @unchecked Sendable {

    static let schema = "binder_requests"

    // MARK: - Fields

    @ID(key: .id)
    var id: UUID?

    /// The full binder specification, serialised as JSON.
    /// Fluent stores this in a TEXT column via `Codable`.
    @Field(key: "definition")
    var definition: BinderSpec

    /// Set automatically when the record is created.
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    /// Local path to the generated PDF.  Nil until generation completes.
    @OptionalField(key: "pdf_path")
    var pdfPath: String?

    // MARK: - Lifecycle

    init() {}

    init(id: UUID? = nil, definition: BinderSpec, pdfPath: String? = nil) {
        self.id = id
        self.definition = definition
        self.pdfPath = pdfPath
    }
}
