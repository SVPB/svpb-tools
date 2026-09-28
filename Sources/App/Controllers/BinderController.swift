import Fluent
import Foundation
import Vapor

/// Handles binder-related routes: the interactive HTML pages and the REST API
/// for creating, polling, and downloading personalised binder PDFs.
struct BinderController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        // HTML pages (no auth required)
        routes.get("binder-constructor", use: binderConstructorPage)
        routes.post("binder-constructor", "check", use: checkBindersYAML)
        routes.post("binder-constructor", "yaml", use: writeBindersYAML)
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

    // MARK: - binders.yaml checking

    /// The body of `POST /binder-constructor/check`.
    struct BindersYAMLCheckRequest: Content {
        /// The branch whose catalogue the entries are checked against.
        let branch: String
        /// The YAML to check, in `binders.yaml` shape.
        let yaml: String
    }

    /// The outcome of `POST /binder-constructor/check`.
    struct BindersYAMLCheckResult: Content {
        /// Whether the build would accept the file. Unresolved tunes do not make
        /// it invalid, just as they do not stop a build storing it.
        let valid: Bool
        /// Why the file was rejected, in the words the build log would use.
        let problem: String?
        /// Entries naming tunes the branch's catalogue does not contain.
        let unresolved: [UnresolvedTune]
        /// The file as decoded, or `nil` where it was rejected.
        ///
        /// The decoder's own result, handed to the browser so the constructor
        /// can load a pasted file back into the editor rather than only judging
        /// it (#60). `OfficialBinder` encodes to exactly the JSON the page
        /// wants — one-line titles as bare strings, `toc: true` as a bare flag,
        /// nothing written that the file did not say — so there is no DTO here
        /// and no second description of the format to keep in step.
        let binders: [OfficialBinder]?

        struct UnresolvedTune: Content {
            let binder: String
            let section: String
            let tune: String
        }
    }

    /// The body of `POST /binder-constructor/yaml`.
    struct BindersYAMLWriteRequest: Content {
        /// The branch whose catalogue the entries are checked against.
        let branch: String
        /// The binders to write, in file order.
        let binders: [OfficialBinder]
    }

    /// The outcome of `POST /binder-constructor/yaml`: the file, and the same
    /// verdict `check` would give on it.
    struct BindersYAMLWriteResult: Content {
        /// The text of `binders.yaml`, or `nil` where the binders could not be
        /// written at all.
        let yaml: String?
        let valid: Bool
        let problem: String?
        let unresolved: [BindersYAMLCheckResult.UnresolvedTune]
    }

    /// `POST /binder-constructor/check` — runs YAML through the same decoder and
    /// checks the build applies to `binders.yaml`, so the constructor can say
    /// "this parses" instead of leaving it to the next push to find out.
    ///
    /// Always answers 200 with the verdict; a rejected file is a result, not an
    /// error. Nothing is stored.
    @Sendable
    func checkBindersYAML(req: Request) async throws -> BindersYAMLCheckResult {
        let body = try req.content.decode(BindersYAMLCheckRequest.self)

        let file: BindersFile
        do {
            file = try BinderDefinitionLoader.decode(body.yaml)
        } catch {
            return BindersYAMLCheckResult(valid: false, problem: "\(error)", unresolved: [], binders: nil)
        }

        return BindersYAMLCheckResult(valid: true, problem: nil,
                                      unresolved: try await unresolved(in: file, branch: body.branch, on: req),
                                      binders: file.binders)
    }

    /// `POST /binder-constructor/yaml` — writes a set of binders out as the text
    /// of a `binders.yaml`, and checks its own output (#60).
    ///
    /// Generation used to be string concatenation in the page, where nothing in
    /// the test suite could reach it; here it is `BinderDefinitionLoader.encode`,
    /// the inverse of the decoder the build uses, so a round trip is a thing a
    /// Swift test can assert.
    ///
    /// The check is not a courtesy: the page used to call `check` straight after
    /// generating, and doing it here saves the round trip and makes the verdict
    /// one about the bytes actually handed over, not about what the page
    /// believes it sent.
    @Sendable
    func writeBindersYAML(req: Request) async throws -> BindersYAMLWriteResult {
        let body = try req.content.decode(BindersYAMLWriteRequest.self)

        let yaml: String
        do {
            yaml = try BinderDefinitionLoader.encode(BindersFile(binders: body.binders))
        } catch {
            return BindersYAMLWriteResult(yaml: nil, valid: false, problem: "\(error)", unresolved: [])
        }

        // Decoding what we just wrote is what makes this a check rather than a
        // claim: everything `problems(in:)` rejects is found here, on the file
        // the pipe major is about to commit.
        let file: BindersFile
        do {
            file = try BinderDefinitionLoader.decode(yaml)
        } catch {
            return BindersYAMLWriteResult(yaml: yaml, valid: false, problem: "\(error)", unresolved: [])
        }
        return BindersYAMLWriteResult(yaml: yaml, valid: true, problem: nil,
                                      unresolved: try await unresolved(in: file, branch: body.branch, on: req))
    }

    /// Entries of `file` naming tunes `branch` does not have, as the wire says them.
    private func unresolved(in file: BindersFile, branch: String,
                            on req: Request) async throws -> [BindersYAMLCheckResult.UnresolvedTune] {
        let slugs = try await Tune.query(on: req.db)
            .filter(\.$branch.$id == branch)
            .all()
            .map(\.slug)
        return BinderDefinitionLoader
            .unresolvedEntries(in: file, catalogueSlugs: Set(slugs))
            .map { BindersYAMLCheckResult.UnresolvedTune(binder: $0.binder, section: $0.section, tune: $0.tune) }
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
