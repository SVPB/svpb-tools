import Fluent
import Foundation
import SVGPDFKit
import Vapor

// MARK: - BinderService

/// Assembles personalised binder PDFs from pre-built per-part SVG sources.
///
/// Each part's SVG files (produced during the build pipeline and stored in
/// `Part.svgPaths`) are fed in order to `SVGPDFConverter`, which handles page
/// numbering via `ConversionOptions.startingPageNumber`. A titled section gets
/// a generated divider page (`DividerPageRenderer`) ahead of its first tune.
///
/// Binder PDFs are written to `<musicWorkspace>/binders/<id>.pdf` and the
/// path is persisted in the `BinderRequest` record so the download endpoint
/// can serve the file.
actor BinderService {

    private let musicWorkspaceURL: URL
    private let dividerRenderer = DividerPageRenderer()

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
        logger.info("[BinderService] \(requestID): building '\(spec.name)' — branch '\(spec.branch)', \(spec.sections.count) section(s), \(spec.entries.count) entr(ies)")

        let binderPages = try await pages(for: spec, requestID: requestID, db: db, logger: logger)
        let tunePageCount = binderPages.count(where: { if case .tune = $0 { true } else { false } })

        logger.info("[BinderService] \(requestID): collected \(binderPages.count) SVG source(s) total, \(tunePageCount) of them tune pages")
        guard tunePageCount > 0 else {
            throw Abort(.unprocessableEntity, reason: "No SVG sources found for binder '\(spec.name)'")
        }
        let svgSources = binderPages.map(\.source)

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

    /// One page of an assembled binder, in the order it will appear.
    enum Page {
        /// A pre-rendered tune page on disk.
        case tune(path: String)
        /// A generated divider page ahead of a titled section.
        case divider(title: String, svg: String)

        var source: SVGSource {
            switch self {
            case .tune(let path): .fileURL(URL(fileURLWithPath: path))
            case .divider(_, let svg): .string(svg)
            }
        }
    }

    /// Resolves `spec` to the binder's pages, in order: each section's tune pages,
    /// preceded by a divider page when the section is titled.
    func pages(for spec: BinderSpec, requestID: UUID, db: Database, logger: Logger) async throws -> [Page] {
        var pages: [Page] = []

        for (sectionIndex, section) in spec.sections.enumerated() {
            // The divider goes in only once the section has a page to follow it,
            // so a section whose tunes all fail to resolve leaves no orphan title.
            var pendingDivider = section.dividerTitle

            for entry in section.entries {
                let paths = try await svgPaths(for: entry, branch: spec.branch,
                                               requestID: requestID, db: db, logger: logger)
                guard !paths.isEmpty else { continue }

                if let title = pendingDivider {
                    pendingDivider = nil
                    do {
                        pages.append(.divider(title: title, svg: try dividerRenderer.render(title: title)))
                        logger.debug("[BinderService] \(requestID): adding divider page '\(title)' ahead of section \(sectionIndex + 1)")
                    } catch {
                        // A binder missing a divider is still a usable binder.
                        logger.error("[BinderService] \(requestID): divider page '\(title)' failed to render — omitting it: \(error)")
                    }
                }

                pages.append(contentsOf: paths.map { .tune(path: $0) })
            }

            if let title = pendingDivider {
                logger.warning("[BinderService] \(requestID): section '\(title)' has no pages — omitting its divider")
            }
        }
        return pages
    }

    /// The SVG page paths for one binder entry, in order, or an empty array when
    /// the tune or all of its requested parts cannot be found.
    private func svgPaths(
        for entry: BinderEntry,
        branch: String,
        requestID: UUID,
        db: Database,
        logger: Logger
    ) async throws -> [String] {
        logger.debug("[BinderService] \(requestID): looking up tune '\(entry.tuneSlug)'")
        guard let tune = try await Tune.query(on: db)
            .filter(\.$branch.$id == branch)
            .filter(\.$slug == entry.tuneSlug)
            .first(),
            let tuneID = tune.id else {
            logger.warning("[BinderService] \(requestID): tune '\(entry.tuneSlug)' not found in branch '\(branch)' — skipping")
            return []
        }
        logger.debug("[BinderService] \(requestID): tune '\(entry.tuneSlug)' found, requesting \(entry.parts.count) part(s): \(entry.parts.joined(separator: ", "))")

        var result: [String] = []
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
                result.append(contentsOf: paths)
            }
        }
        return result
    }
}
