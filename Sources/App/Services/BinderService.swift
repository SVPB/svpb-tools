import Fluent
import Foundation
import SVGPDFKit
import Vapor

// MARK: - BinderService

/// Assembles binder PDFs from the tunes' ABC sources — both the personalised ones a
/// member builds for themselves and the band's official binders, which `binders.yaml`
/// declares and `BuildService` asks for after every build.
///
/// Both go through the same pipeline: an official binder is a `BinderSpec` like any
/// other (`OfficialBinder.spec(branch:)`), and only where the PDF is written and what
/// happens to it afterwards differ — a personalised binder stays on the server, an
/// official one goes to Box.
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
/// Personalised binder PDFs are written to `<musicWorkspace>/binders/<id>.pdf` and the
/// path is persisted in the `BinderRequest` record so the download endpoint can serve the
/// file. Official binders are written where the build asks (`assemble(_:branch:in:db:logger:)`).
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

        let binderPages = try await pages(for: spec, label: requestID.uuidString, db: db, logger: logger)
        let tunePageCount = binderPages.count(where: { if case .divider = $0 { false } else { true } })

        logger.info("[BinderService] \(requestID): collected \(binderPages.count) page(s) total, \(tunePageCount) of them tune pages")
        guard tunePageCount > 0 else {
            throw Abort(.unprocessableEntity, reason: "No SVG sources found for binder '\(spec.name)'")
        }
        let svgSources = binderPages.map(\.source)

        logger.info("[BinderService] \(requestID): starting PDF conversion")
        let pdfData = try Self.convert(svgSources)
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

        /// The tune this page belongs to, or `nil` for a divider.
        var slug: String? {
            switch self {
            case .tune(let slug, _): slug
            case .prebuilt(let slug, _): slug
            case .divider: nil
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
    func pages(for spec: BinderSpec, label: String, db: Database, logger: Logger) async throws -> [Page] {
        var pages: [Page] = []

        for (sectionIndex, section) in spec.sections.enumerated() {
            // The divider goes in only once the section has a page to follow it,
            // so a section whose tunes all fail to resolve leaves no orphan title.
            var pendingDivider = section.dividerTitle

            for entry in section.entries {
                let resolutions = try await resolve(entry, branch: spec.branch,
                                                    label: label, db: db, logger: logger)
                guard !resolutions.isEmpty else { continue }

                if let title = pendingDivider {
                    pendingDivider = nil
                    do {
                        pages.append(.divider(title: title, svg: try dividerRenderer.render(title: title)))
                        logger.debug("[BinderService] \(label): adding divider page '\(title)' ahead of section \(sectionIndex + 1)")
                    } catch {
                        // A binder missing a divider is still a usable binder.
                        logger.error("[BinderService] \(label): divider page '\(title)' failed to render — omitting it: \(error)")
                    }
                }

                for resolution in resolutions {
                    pages.append(contentsOf: engrave(resolution, firstPageNumber: pages.count + 1,
                                                     label: label, logger: logger))
                }
            }

            if let title = pendingDivider {
                logger.warning("[BinderService] \(label): section '\(title)' has no pages — omitting its divider")
            }
        }
        return pages
    }

    // MARK: - Official binder assembly

    /// What assembling one official binder produced.
    struct Assembly: Sendable {
        /// Where the binder PDF was written.
        let url: URL
        /// Pages in the finished binder, dividers included.
        let pageCount: Int
        /// Slugs the binder names that contributed no pages, in the order the file
        /// names them. The build logs these: a typo must cost a visible warning
        /// rather than a silently thinner binder.
        let missing: [String]
    }

    /// Assembles one of `binders.yaml`'s binders and writes it to `directory/<binder.output>`.
    ///
    /// The same pipeline as a personalised binder, over the spec `OfficialBinder.spec(branch:)`
    /// maps the file onto — one `SVGPDFConverter` call over re-engraved pages, so the footers
    /// number continuously across the whole binder.
    ///
    /// `binder.output` is written as given. `BinderDefinitionLoader` rejects a file whose
    /// outputs are anything but a bare `.pdf` filename, so no binder reaching here can name a
    /// path that leaves `directory`.
    ///
    /// - Throws: when the binder resolved to no tune pages at all — an empty PDF is not a
    ///   binder, and uploading one over last week's would be worse than uploading nothing.
    func assemble(
        _ binder: OfficialBinder,
        branch: String,
        in directory: URL,
        db: Database,
        logger: Logger
    ) async throws -> Assembly {
        let spec = binder.spec(branch: branch)
        let label = binder.output
        logger.info("[BinderService] \(label): assembling '\(binder.name)' — branch '\(branch)', \(spec.sections.count) section(s), \(spec.entries.count) entr(ies)")

        let binderPages = try await pages(for: spec, label: label, db: db, logger: logger)
        let resolved = Set(binderPages.compactMap(\.slug))
        guard resolved.count > 0 else {
            throw Abort(.unprocessableEntity,
                        reason: "no tune in '\(binder.name)' resolved to any pages")
        }

        var missing: [String] = []
        for entry in spec.entries where !resolved.contains(entry.tuneSlug) && !missing.contains(entry.tuneSlug) {
            missing.append(entry.tuneSlug)
        }

        let pdfData = try Self.convert(binderPages.map(\.source))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(binder.output)
        try pdfData.write(to: url, options: .atomic)
        logger.info("[BinderService] \(label): wrote \(binderPages.count) page(s) to \(url.path) (\(pdfData.count) bytes)")

        return Assembly(url: url, pageCount: binderPages.count, missing: missing)
    }

    // MARK: - PDF conversion

    /// Renders an ordered page list to one PDF.
    ///
    /// The footers are already binder-relative: CeolKit engraved them at the page numbers
    /// `pages(for:…)` assigned. `SVGPDFConverter` looks for a `<text>` placeholder that
    /// CeolKit never emits and silently changes nothing when it misses
    /// (sbeitzel/SVGPDFKit#3), so leaving injection on would only hide a second,
    /// contradictory numbering scheme behind a no-op.
    private static func convert(_ sources: [SVGSource]) throws -> Data {
        var options = ConversionOptions()
        options.injectPageNumbers = false
        return try SVGPDFConverter(options: options).convert(sources: sources)
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
        label: String,
        db: Database,
        logger: Logger
    ) async throws -> [Resolution] {
        logger.debug("[BinderService] \(label): looking up tune '\(entry.tuneSlug)'")
        guard let tune = try await Tune.query(on: db)
            .filter(\.$branch.$id == branch)
            .filter(\.$slug == entry.tuneSlug)
            .first(),
            let tuneID = tune.id else {
            logger.warning("[BinderService] \(label): tune '\(entry.tuneSlug)' not found in branch '\(branch)' — skipping")
            return []
        }
        let abcURL = tune.abcPath.map { URL(fileURLWithPath: $0) }

        // An entry with no parts asks for the tune's one set of pages, which is what an
        // official binder always wants: per-part rendering is deferred past MVP (#20), and
        // every `Part` row of a tune points at the same `svgPaths` today, so naming them all
        // would repeat the whole score once per part. One row stands for the tune until #20
        // makes the parts differ, at which point this is where the list comes back.
        let partNames: [String]
        if entry.parts.isEmpty {
            guard let representative = try await Part.query(on: db)
                .filter(\.$tune.$id == tuneID)
                .sort(\.$name)
                .first() else {
                logger.warning("[BinderService] \(label): tune '\(entry.tuneSlug)' has no parts — skipping")
                return []
            }
            partNames = [representative.name]
        } else {
            partNames = entry.parts
        }
        logger.debug("[BinderService] \(label): tune '\(entry.tuneSlug)' found, requesting \(partNames.count) part(s): \(partNames.joined(separator: ", "))")

        var result: [Resolution] = []
        for partName in partNames {
            guard let part = try await Part.query(on: db)
                .filter(\.$tune.$id == tuneID)
                .filter(\.$name == partName)
                .first() else {
                logger.warning("[BinderService] \(label): part '\(partName)' not found for tune '\(entry.tuneSlug)' — skipping")
                continue
            }

            let paths = part.svgPaths ?? []
            if paths.isEmpty {
                logger.warning("[BinderService] \(label): part '\(partName)' of '\(entry.tuneSlug)' has no SVG paths — skipping")
            } else {
                logger.debug("[BinderService] \(label): resolved \(paths.count) page(s) for '\(entry.tuneSlug)' / '\(partName)'")
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
        label: String,
        logger: Logger
    ) -> [Page] {
        let fallback = resolution.prebuiltPaths.map { Page.prebuilt(slug: resolution.slug, path: $0) }

        guard let abcURL = resolution.abcURL else {
            logger.error("[BinderService] \(label): tune '\(resolution.slug)' has no ABC source on record — reusing the build's \(fallback.count) page(s), whose footers number from 1")
            return fallback
        }

        do {
            let rendering = try tuneRenderer.render(abcAt: abcURL, firstPageNumber: firstPageNumber)
            guard !rendering.pages.isEmpty else {
                logger.error("[BinderService] \(label): re-engraving '\(resolution.slug)' from \(abcURL.path) produced no pages — reusing the build's \(fallback.count), whose footers number from 1")
                return fallback
            }
            if !rendering.printsPageNumbers {
                logger.warning("[BinderService] \(label): '\(resolution.slug)' asks for a footer that names neither $P nor ${pagenumber}, so its \(rendering.pages.count) page(s) print no page number — they are numbered from \(firstPageNumber), they just do not say so")
            }
            logger.debug("[BinderService] \(label): engraved \(rendering.pages.count) page(s) of '\(resolution.slug)' / '\(resolution.partName)' from page \(firstPageNumber)")
            return rendering.pages.map { .tune(slug: resolution.slug, svg: $0) }
        } catch {
            logger.error("[BinderService] \(label): re-engraving '\(resolution.slug)' from \(abcURL.path) failed — reusing the build's \(fallback.count) page(s), whose footers number from 1: \(error)")
            return fallback
        }
    }
}
