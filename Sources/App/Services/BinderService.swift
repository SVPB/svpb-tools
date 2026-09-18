import Fluent
import Foundation
import SVGPDFKit
import Vapor

// MARK: - BinderService

/// Assembles personalised binder PDFs from the tunes' ABC sources.
///
/// Each entry's tune is re-engraved by `TunePageRenderer` at the page number it opens on
/// within *this* binder, then the pages are fed in order to `SVGPDFConverter`. A titled
/// section gets a generated divider page (`DividerPageRenderer`) ahead of its first tune.
///
/// Re-engraving rather than reusing the build's pages is what makes the page numbers
/// right (#19). CeolKit outlines every glyph it draws, so a footer reading "1" is path
/// geometry by the time a binder sees it and no downstream tool can rewrite it — which is
/// why `SVGPDFConverter`'s own page-number injection is switched off here rather than
/// left on to do nothing. The build's pages (`Part.svgPaths`) remain the source of the
/// per-tune PDFs, and they are what a binder falls back to when a tune has no ABC on
/// record; those pages number from 1 and say so in the log.
///
/// Divider pages are counted but not numbered, the way a book's part titles are: the
/// tune after a divider is numbered as though the divider were a page, because it is one.
///
/// Binder PDFs are written to `<musicWorkspace>/binders/<id>.pdf` and the
/// path is persisted in the `BinderRequest` record so the download endpoint
/// can serve the file.
actor BinderService {

    private let musicWorkspaceURL: URL
    private let dividerRenderer = DividerPageRenderer()
    private let tuneRenderer = TunePageRenderer()

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
        let tunePageCount = binderPages.count(where: { if case .divider = $0 { false } else { true } })

        logger.info("[BinderService] \(requestID): collected \(binderPages.count) page(s) total, \(tunePageCount) of them tune pages")
        guard tunePageCount > 0 else {
            throw Abort(.unprocessableEntity, reason: "No SVG sources found for binder '\(spec.name)'")
        }
        let svgSources = binderPages.map(\.source)

        logger.info("[BinderService] \(requestID): starting PDF conversion")
        var options = ConversionOptions()
        // The footers are already binder-relative: CeolKit engraved them at the page
        // numbers `pages(for:…)` assigned. `SVGPDFConverter` looks for a `<text>`
        // placeholder that CeolKit never emits and silently changes nothing when it
        // misses (sbeitzel/SVGPDFKit#3), so leaving injection on would only hide a
        // second, contradictory numbering scheme behind a no-op.
        options.injectPageNumbers = false
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
        /// A tune page engraved for this binder, so its footer numbers from the binder.
        case tune(slug: String, svg: String)
        /// A page the build produced, reused because the tune could not be re-engraved.
        /// Its footer numbers from 1 within its own tune.
        case prebuilt(slug: String, path: String)
        /// A generated divider page ahead of a titled section.
        case divider(title: String, svg: String)

        var source: SVGSource {
            switch self {
            case .tune(_, let svg): .string(svg)
            case .prebuilt(_, let path): .fileURL(URL(fileURLWithPath: path))
            case .divider(_, let svg): .string(svg)
            }
        }
    }

    /// Resolves `spec` to the binder's pages, in order: each section's tune pages,
    /// preceded by a divider page when the section is titled.
    ///
    /// Every tune is engraved at the page number it lands on, so the count of pages
    /// already collected *is* the numbering: the next page to be produced prints
    /// `pages.count + 1`. That is why an entry is resolved before it is engraved —
    /// whether the divider ahead of it goes in decides what number it opens on.
    func pages(for spec: BinderSpec, requestID: UUID, db: Database, logger: Logger) async throws -> [Page] {
        var pages: [Page] = []

        for (sectionIndex, section) in spec.sections.enumerated() {
            // The divider goes in only once the section has a page to follow it,
            // so a section whose tunes all fail to resolve leaves no orphan title.
            var pendingDivider = section.dividerTitle

            for entry in section.entries {
                let resolutions = try await resolve(entry, branch: spec.branch,
                                                    requestID: requestID, db: db, logger: logger)
                guard !resolutions.isEmpty else { continue }

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

                for resolution in resolutions {
                    pages.append(contentsOf: engrave(resolution, firstPageNumber: pages.count + 1,
                                                     requestID: requestID, logger: logger))
                }
            }

            if let title = pendingDivider {
                logger.warning("[BinderService] \(requestID): section '\(title)' has no pages — omitting its divider")
            }
        }
        return pages
    }

    // MARK: - Resolution

    /// One part of one entry, and what its pages can be engraved from.
    private struct Resolution {
        let slug: String
        let partName: String
        /// The tune's ABC source, when the catalogue has one to re-engrave.
        let abcURL: URL?
        /// The pages the build produced for this part. Never empty: a part with no
        /// pages is a part the build never converted, and a binder skips it.
        let prebuiltPaths: [String]
    }

    /// The parts of one binder entry that have pages, in the order they were asked for,
    /// or an empty array when the tune or all of its requested parts cannot be found.
    ///
    /// A part is still resolved through its `Part` record rather than from the ABC alone:
    /// the build is the authority on whether a part produced pages, so a binder includes
    /// exactly the parts it included before this became a re-engraving (#20 is what will
    /// make those parts differ from one another).
    private func resolve(
        _ entry: BinderEntry,
        branch: String,
        requestID: UUID,
        db: Database,
        logger: Logger
    ) async throws -> [Resolution] {
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

        let abcURL = tune.abcPath.map { URL(fileURLWithPath: $0) }

        var result: [Resolution] = []
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
                logger.debug("[BinderService] \(requestID): resolved \(paths.count) page(s) for '\(entry.tuneSlug)' / '\(partName)'")
                result.append(Resolution(slug: entry.tuneSlug, partName: partName,
                                         abcURL: abcURL, prebuiltPaths: paths))
            }
        }
        return result
    }

    /// The pages for one resolved part, engraved so the first prints `firstPageNumber`.
    ///
    /// Never throws: a tune that cannot be re-engraved falls back to the pages the build
    /// made of it. Those pages carry the build's footers, which number from 1 within the
    /// tune, so the fallback is logged at `error` — it is the silent version of exactly
    /// the bug this re-engraving exists to fix.
    private func engrave(
        _ resolution: Resolution,
        firstPageNumber: Int,
        requestID: UUID,
        logger: Logger
    ) -> [Page] {
        let fallback = resolution.prebuiltPaths.map { Page.prebuilt(slug: resolution.slug, path: $0) }

        guard let abcURL = resolution.abcURL else {
            logger.error("[BinderService] \(requestID): tune '\(resolution.slug)' has no ABC source on record — reusing the build's \(fallback.count) page(s), whose footers number from 1")
            return fallback
        }

        do {
            let rendering = try tuneRenderer.render(abcAt: abcURL, firstPageNumber: firstPageNumber)
            guard !rendering.pages.isEmpty else {
                logger.error("[BinderService] \(requestID): re-engraving '\(resolution.slug)' from \(abcURL.path) produced no pages — reusing the build's \(fallback.count), whose footers number from 1")
                return fallback
            }
            if !rendering.printsPageNumbers {
                logger.warning("[BinderService] \(requestID): '\(resolution.slug)' asks for a footer that names neither $P nor ${pagenumber}, so its \(rendering.pages.count) page(s) print no page number — they are numbered from \(firstPageNumber), they just do not say so")
            }
            logger.debug("[BinderService] \(requestID): engraved \(rendering.pages.count) page(s) of '\(resolution.slug)' / '\(resolution.partName)' from page \(firstPageNumber)")
            return rendering.pages.map { .tune(slug: resolution.slug, svg: $0) }
        } catch {
            logger.error("[BinderService] \(requestID): re-engraving '\(resolution.slug)' from \(abcURL.path) failed — reusing the build's \(fallback.count) page(s), whose footers number from 1: \(error)")
            return fallback
        }
    }
}
