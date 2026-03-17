import Fluent
import Foundation
import SVGPDFKit
import Vapor

// MARK: - BinderService

/// Assembles personalised binder PDFs from pre-built per-part SVG sources.
///
/// Each part's SVG files (produced during the build pipeline and stored in
/// `Part.svgPaths`) are fed in order to `SVGPDFConverter`, which handles page
/// numbering via `ConversionOptions.startingPageNumber`.
///
/// Binder PDFs are written to `<musicWorkspace>/binders/<id>.pdf` and the
/// path is persisted in the `BinderRequest` record so the download endpoint
/// can serve the file.
actor BinderService {

    private let musicWorkspaceURL: URL

    init(musicWorkspacePath: String) {
        self.musicWorkspaceURL = URL(fileURLWithPath: musicWorkspacePath, isDirectory: true)
    }

    // MARK: - Public API

    /// Generates the binder PDF for `requestID` in the background.
    ///
    /// This method never throws — all errors are logged so the caller can
    /// fire-and-forget and let the client poll for completion.
    func generateBinder(requestID: UUID, db: Database, logger: Logger) async {
        do {
            try await _generateBinder(requestID: requestID, db: db, logger: logger)
        } catch {
            logger.error("[BinderService] Binder \(requestID) failed: \(error)")
        }
    }

    // MARK: - Private implementation

    private func _generateBinder(requestID: UUID, db: Database, logger: Logger) async throws {
        guard let request = try await BinderRequest.find(requestID, on: db) else {
            throw Abort(.notFound, reason: "BinderRequest \(requestID) not found")
        }

        let spec = request.definition
        var svgSources: [SVGSource] = []

        for entry in spec.entries {
            guard let tune = try await Tune.query(on: db)
                .filter(\.$branch.$id == spec.branch)
                .filter(\.$slug == entry.tuneSlug)
                .first(),
                let tuneID = tune.id else {
                logger.warning("[BinderService] Tune '\(entry.tuneSlug)' not found in branch '\(spec.branch)'")
                continue
            }

            for partName in entry.parts {
                guard let part = try await Part.query(on: db)
                    .filter(\.$tune.$id == tuneID)
                    .filter(\.$name == partName)
                    .first() else {
                    logger.warning("[BinderService] Part '\(partName)' not found for tune '\(entry.tuneSlug)'")
                    continue
                }

                for svgPath in part.svgPaths ?? [] {
                    svgSources.append(.fileURL(URL(fileURLWithPath: svgPath)))
                }
            }
        }

        guard !svgSources.isEmpty else {
            throw Abort(.unprocessableEntity, reason: "No SVG sources found for binder '\(spec.name)'")
        }

        var options = ConversionOptions()
        options.startingPageNumber = 1
        let converter = SVGPDFConverter(options: options)
        let pdfData = try converter.convert(sources: svgSources)

        // Write to binders directory
        let bindersDir = musicWorkspaceURL
            .appendingPathComponent("binders", isDirectory: true)
        try FileManager.default.createDirectory(at: bindersDir, withIntermediateDirectories: true)

        let pdfURL = bindersDir.appendingPathComponent("\(requestID).pdf")
        try pdfData.write(to: pdfURL, options: .atomic)

        request.pdfPath = pdfURL.path
        try await request.save(on: db)
        logger.info("[BinderService] Binder \(requestID) ready at \(pdfURL.path)")
    }
}
