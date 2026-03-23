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
        logger.info("[BinderService] \(requestID): looking up request")
        guard let request = try await BinderRequest.find(requestID, on: db) else {
            throw Abort(.notFound, reason: "BinderRequest \(requestID) not found")
        }

        let spec = request.definition
        logger.info("[BinderService] \(requestID): building '\(spec.name)' — branch '\(spec.branch)', \(spec.entries.count) entr(ies)")

        var svgSources: [SVGSource] = []

        for entry in spec.entries {
            logger.debug("[BinderService] \(requestID): looking up tune '\(entry.tuneSlug)'")
            guard let tune = try await Tune.query(on: db)
                .filter(\.$branch.$id == spec.branch)
                .filter(\.$slug == entry.tuneSlug)
                .first(),
                let tuneID = tune.id else {
                logger.warning("[BinderService] \(requestID): tune '\(entry.tuneSlug)' not found in branch '\(spec.branch)' — skipping")
                continue
            }
            logger.debug("[BinderService] \(requestID): tune '\(entry.tuneSlug)' found, requesting \(entry.parts.count) part(s): \(entry.parts.joined(separator: ", "))")

            for partName in entry.parts {
                guard let part = try await Part.query(on: db)
                    .filter(\.$tune.$id == tuneID)
                    .filter(\.$name == partName)
                    .first() else {
                    logger.warning("[BinderService] \(requestID): part '\(partName)' not found for tune '\(entry.tuneSlug)' — skipping")
                    continue
                }

                let paths = part.svgPaths ?? []
                if paths.isEmpty {
                    logger.warning("[BinderService] \(requestID): part '\(partName)' of '\(entry.tuneSlug)' has no SVG paths — skipping")
                } else {
                    logger.debug("[BinderService] \(requestID): adding \(paths.count) SVG page(s) for '\(entry.tuneSlug)' / '\(partName)'")
                    for svgPath in paths {
                        svgSources.append(.fileURL(URL(fileURLWithPath: svgPath)))
                    }
                }
            }
        }

        logger.info("[BinderService] \(requestID): collected \(svgSources.count) SVG source(s) total")
        guard !svgSources.isEmpty else {
            throw Abort(.unprocessableEntity, reason: "No SVG sources found for binder '\(spec.name)'")
        }

        logger.info("[BinderService] \(requestID): starting PDF conversion")
        var options = ConversionOptions()
        options.startingPageNumber = 1
        let converter = SVGPDFConverter(options: options)
        let pdfData = try converter.convert(sources: svgSources)
        logger.info("[BinderService] \(requestID): PDF conversion complete (\(pdfData.count) bytes)")

        let bindersDir = musicWorkspaceURL
            .appendingPathComponent("binders", isDirectory: true)
        logger.debug("[BinderService] \(requestID): creating binders directory at \(bindersDir.path)")
        try FileManager.default.createDirectory(at: bindersDir, withIntermediateDirectories: true)

        let pdfURL = bindersDir.appendingPathComponent("\(requestID).pdf")
        logger.info("[BinderService] \(requestID): writing PDF to \(pdfURL.path)")
        try pdfData.write(to: pdfURL, options: .atomic)

        request.pdfPath = pdfURL.path
        try await request.save(on: db)
        logger.info("[BinderService] \(requestID): ready ✓")
    }
}
