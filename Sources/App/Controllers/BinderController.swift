import Fluent
import Foundation
import Vapor

/// Handles binder-related routes: the interactive HTML pages and the REST API
/// for creating, polling, and downloading personalised binder PDFs.
struct BinderController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        // HTML pages (no auth required)
        routes.get("binder-constructor", use: binderConstructorPage)
        routes.get("binder-builder", use: binderBuilderPage)

        // REST API
        let binders = routes.grouped("binders")
        binders.post(use: createBinder)
        binders.get(":id", use: binderStatus)
        binders.get(":id", "download", use: downloadBinder)
    }

    // MARK: - HTML Pages

    /// `GET /binder-constructor`
    ///
    /// Renders the interactive YAML generator for the pipe major.
    /// No server-side state is created; the YAML is assembled client-side.
    @Sendable
    func binderConstructorPage(req: Request) async throws -> View {
        struct BinderConstructorContext: Encodable {
            let appVersion: String
            let isAdmin: Bool
            let currentUser: String?
        }
        let user = await req.sessionUser()
        let ctx = BinderConstructorContext(
            appVersion: AppVersion.current,
            isAdmin: user?.role == .admin,
            currentUser: user.map { $0.displayName ?? $0.slackUserId }
        )
        return try await req.view.render("binder-constructor", ctx)
    }

    /// `GET /binder-builder`
    ///
    /// Renders the personal binder builder page.
    /// An optional `spec` query parameter (Base64-encoded JSON) pre-populates
    /// the selection so a shared binder URL can be restored.
    @Sendable
    func binderBuilderPage(req: Request) async throws -> View {
        struct BinderBuilderContext: Encodable {
            let appVersion: String
            let isAdmin: Bool
            let currentUser: String?
            let encodedSpec: String?
        }
        let user = await req.sessionUser()
        let ctx = BinderBuilderContext(
            appVersion: AppVersion.current,
            isAdmin: user?.role == .admin,
            currentUser: user.map { $0.displayName ?? $0.slackUserId },
            encodedSpec: req.query[String.self, at: "spec"]
        )
        return try await req.view.render("binder-builder", ctx)
    }

    // MARK: - REST API

    /// `POST /binders` — submit a binder spec; returns the new binder ID.
    ///
    /// The request body must be a JSON-encoded `BinderSpec`.
    /// Generation runs asynchronously; the client should poll `GET /binders/:id`.
    @Sendable
    func createBinder(req: Request) async throws -> Response {
        let spec = try req.content.decode(BinderSpec.self)

        // Validate that the referenced branch exists
        guard try await Branch.find(spec.branch, on: req.db) != nil else {
            throw Abort(.unprocessableEntity, reason: "Branch '\(spec.branch)' not found")
        }

        let binderRequest = BinderRequest(definition: spec)
        try await binderRequest.save(on: req.db)
        let id = try binderRequest.requireID()

        // Fire-and-forget background generation.
        // Use req.application.db — req.db may be reclaimed once the response is sent.
        let binderService = req.application.binderService
        let appDB = req.application.db
        let logger = req.logger
        Task {
            await binderService.generateBinder(requestID: id, db: appDB, logger: logger)
        }

        let dto = try BinderStatusDTO(from: binderRequest)
        return try await dto.encodeResponse(status: .accepted, for: req)
    }

    /// `GET /binders/:id` — poll for binder status.
    @Sendable
    func binderStatus(req: Request) async throws -> BinderStatusDTO {
        let binderRequest = try await findBinder(req: req)
        return try BinderStatusDTO(from: binderRequest)
    }

    /// `GET /binders/:id/download` — download the generated PDF.
    @Sendable
    func downloadBinder(req: Request) async throws -> Response {
        let binderRequest = try await findBinder(req: req)

        guard let pdfPath = binderRequest.pdfPath else {
            throw Abort(.serviceUnavailable, reason: "Binder PDF is not ready yet")
        }

        let pdfURL = URL(fileURLWithPath: pdfPath)
        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw Abort(.notFound, reason: "Binder PDF file not found on disk")
        }

        let pdfData = try Data(contentsOf: pdfURL)
        _ = try binderRequest.requireID()
        let filename = "\(binderRequest.definition.name.replacing(/[^a-zA-Z0-9 _-]/, with: "_")).pdf"

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/pdf")
        headers.add(name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
        return Response(status: .ok, headers: headers, body: .init(data: pdfData))
    }

    // MARK: - Helpers

    private func findBinder(req: Request) async throws -> BinderRequest {
        guard let idString = req.parameters.get("id"),
              let id = UUID(uuidString: idString) else {
            throw Abort(.badRequest)
        }
        guard let binderRequest = try await BinderRequest.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        return binderRequest
    }

}
