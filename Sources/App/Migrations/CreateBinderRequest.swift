import Fluent

struct CreateBinderRequest: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(BinderRequest.schema)
            .id()
            // JSON-encoded BinderSpec (TEXT column; serialised via Codable).
            .field("definition", .string, .required)
            .field("created_at", .datetime)
            // Nil until the PDF generation pipeline completes.
            .field("pdf_path", .string)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(BinderRequest.schema).delete()
    }
}
