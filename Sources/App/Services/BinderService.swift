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
/// section gets a generated title page (`TitlePageRenderer`) ahead of its first tune, and a
/// section holding no tunes at all is a title page and nothing else (#46).
///
/// A binder that asks to be **packed** (#48) is engraved a *run* at a time instead — a
/// maximal stretch of consecutive tunes with nothing between them that owns a page anyway —
/// and `TuneRunRenderer` hands the whole run to CeolKit as one document, so two short tunes
/// in a row share a sheet. An entry saying `break: before` ends the run ahead of it, which
/// is how one tune opts back out of sharing. Everything else is unchanged: the runs are
/// numbered from the pages already collected, exactly as single tunes are, and a run that
/// cannot be engraved as one document falls back to engraving its tunes one at a time.
///
/// Re-engraving rather than reusing the build's pages is what makes the page numbers
/// right (#19). CeolKit outlines every glyph it draws, so a footer reading "1" is path
/// geometry by the time a binder sees it and no downstream tool can rewrite it — which is
/// why `SVGPDFConverter`'s own page-number injection is switched off here rather than
/// left on to do nothing. The build's pages (`Part.svgPaths`) remain the source of the
/// per-tune PDFs, and they are what a binder falls back to when a tune has no ABC on
/// record; those pages number from 1 and say so in the log.
///
/// Title pages are counted but not numbered, the way a book's part titles are: the tune
/// after a title page is numbered as though the title page were a page, because it is one.
/// That holds for a binder's cover too — three pages of front matter means the first tune
/// opens on page 4 (#46).
///
/// Personalised binder PDFs are written to `<musicWorkspace>/binders/<id>.pdf` and the
/// path is persisted in the `BinderRequest` record so the download endpoint can serve the
/// file. Official binders are written where the build asks (`assemble(_:branch:in:db:logger:)`).
actor BinderService {

    private let musicWorkspaceURL: URL
    private let titleRenderer = TitlePageRenderer()
    private let tocRenderer = TableOfContentsRenderer()
    private let tuneRenderer = TunePageRenderer()
    private let runRenderer = TuneRunRenderer()

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
        logger.info("[BinderService] \(requestID): building '\(spec.name)' — branch '\(spec.branch)', \(spec.sections.count) section(s), \(spec.entries.count) entr(ies)\(spec.pack ? ", packed" : "")")

        let binderPages = try await pages(for: spec, label: requestID.uuidString, db: db, logger: logger)
        // Pages the binder generated — title pages, contents pages — are not a binder
        // on their own, so only the pages that came from a tune count towards having
        // something to bind.
        let tunePageCount = binderPages.count(where: \.isMusic)

        logger.info("[BinderService] \(requestID): collected \(binderPages.count) page(s) total, \(tunePageCount) of them tune pages")
        guard tunePageCount > 0 else {
            throw Abort(.unprocessableEntity, reason: "No SVG sources found for binder '\(spec.name)'")
        }
        let svgSources = binderPages.map(\.source)

        logger.info("[BinderService] \(requestID): starting PDF conversion")
        let pdfData = try Self.convert(svgSources, logger: logger)
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
        /// A page of music engraved for this binder, so its footer numbers from the
        /// binder. `slugs` names the tunes that *start* on it: one for an unpacked
        /// page, several where a packed run put two short tunes on one sheet, and
        /// none where the page only carries the rest of the tune before it (#48).
        case tune(slugs: [String], svg: String)
        /// A page the build produced, reused because the tune could not be re-engraved.
        /// Its footer numbers from 1 within its own tune, and prints no section name (#67).
        case prebuilt(slug: String, path: String)
        /// A generated page carrying nothing but a title.
        case titlePage(title: BinderTitle, svg: String)
        /// A generated page of the binder's table of contents, and the lines it
        /// carries — which nothing can read back out of the outlined SVG (#47).
        case contents(entries: [TableOfContentsRenderer.Entry], svg: String)

        var source: SVGSource {
            switch self {
            case .tune(_, let svg): .string(svg)
            case .prebuilt(_, let path): .fileURL(URL(fileURLWithPath: path))
            case .titlePage(_, let svg): .string(svg)
            case .contents(_, let svg): .string(svg)
            }
        }

        /// The tunes that open on this page, in the order they appear down it.
        /// Empty for a page the binder itself generated — a title page, or a page
        /// of the contents — and for a page that only continues a packed run.
        var slugs: [String] {
            switch self {
            case .tune(let slugs, _): slugs
            case .prebuilt(let slug, _): [slug]
            case .titlePage, .contents: []
            }
        }

        /// Whether this page carries music at all, as opposed to something the
        /// binder generated for itself. Not the same question as ``slugs``: a tune
        /// running over three pages opens only the first of them.
        var isMusic: Bool {
            switch self {
            case .tune, .prebuilt: true
            case .titlePage, .contents: false
            }
        }
    }

    // MARK: - The plan

    /// What a binder will hold, in order, before any of it has a page number.
    ///
    /// A table of contents is why this exists. Its numbers come from the pages
    /// around it, and its own pages move every number after it, so neither can
    /// be settled in one pass over the spec. The way out is that the *count* of
    /// contents lines is known before anything is drawn: resolving the spec to
    /// a plan settles what the binder holds, reserving the contents pages
    /// settles how long it is, and only then does anything take a number.
    private enum PlanItem {
        /// A title page, and whether the contents lists it — which it does when
        /// the title stands over tunes, and does not when it is a page of its
        /// own, such as the binder's cover.
        case titlePage(BinderTitle, section: Int, listed: Bool)
        /// The binder's table of contents, headed as its section asked.
        case contents(TableOfContentsSpec, heading: String)
        /// One tune, resolved but not yet engraved: it cannot be, until the
        /// page it opens on is known.
        case tune(Resolution)
    }

    /// One line a table of contents will carry, before its page number is known.
    private struct ListedItem {
        /// Index into the plan of the thing this line names, which is what the
        /// line's page number is read from once the plan has been laid out.
        let item: Int
        /// How far the line is indented: 0 for a section, 1 for a tune under one.
        let level: Int
        /// The name printed on the line.
        let text: String
    }

    /// Resolves `spec` to the binder's pages, in order: each section's title page, then
    /// the pages of its tunes, with the binder's table of contents wherever it asked to
    /// sit.
    ///
    /// A section that holds no entries is a title page and nothing else, and goes in
    /// unconditionally — that is how a binder gets a cover, and how two title pages come
    /// to sit on consecutive pages (#46). A section that *does* hold entries keeps its
    /// title back until one of them resolves, so a section whose tunes all fail to resolve
    /// leaves no title standing over nothing.
    ///
    /// Every tune is engraved at the page number it lands on, so the count of pages
    /// already collected *is* the numbering: the next page to be produced prints
    /// `pages.count + 1`. That is why an entry is resolved before it is engraved —
    /// whether the title page ahead of it goes in decides what number it opens on.
    /// Title pages and contents pages are counted this way but print no number of their
    /// own.
    func pages(for spec: BinderSpec, label: String, db: Database, logger: Logger) async throws -> [Page] {
        let items = try await plan(for: spec, label: label, db: db, logger: logger)
        return layOut(items, packing: spec.pack, label: label, logger: logger)
    }

    /// Resolves `spec` to what the binder will hold, without engraving any of it.
    ///
    /// Nothing here needs a page number, and nothing here produces one: the point of the
    /// pass is to settle *what* is in the binder, since that is what decides how long the
    /// table of contents is and therefore what every number after it will be.
    private func plan(for spec: BinderSpec, label: String, db: Database, logger: Logger) async throws -> [PlanItem] {
        var plan: [PlanItem] = []

        for (sectionIndex, section) in spec.sections.enumerated() {
            // A contents section is the table of contents, not a title page: its title
            // is the heading printed over the listing.
            if let toc = section.toc {
                plan.append(.contents(toc, heading: section.contentsHeading))
            }

            // A section with no tunes is the title page. Nothing is waiting on a tune
            // that might never resolve, so it goes in as soon as it is reached.
            guard !section.entries.isEmpty else {
                if let titlePage = section.titlePage {
                    plan.append(.titlePage(titlePage, section: sectionIndex, listed: false))
                } else if section.toc == nil {
                    logger.warning("[BinderService] \(label): section \(sectionIndex + 1) has neither a title nor any tunes — skipping it")
                }
                continue
            }

            // The title goes in only once the section has a page to follow it, so a
            // section whose tunes all fail to resolve leaves no orphan title.
            var pending = section.titlePage

            for entry in section.entries {
                guard var resolution = try await resolve(entry, branch: spec.branch,
                                                         label: label, db: db, logger: logger) else { continue }
                // Only this section's own title: an untitled section's tunes print no name,
                // rather than carrying on with the one before it (#67).
                resolution.sectionName = section.titlePage?.oneLine

                if let title = pending {
                    pending = nil
                    plan.append(.titlePage(title, section: sectionIndex, listed: true))
                }
                plan.append(.tune(resolution))
            }

            if let title = pending {
                logger.warning("[BinderService] \(label): section '\(title.display)' has tunes but none of them resolved — omitting its title page")
            }
        }
        return plan
    }

    /// Turns a plan into the binder's pages, numbering everything as it goes.
    ///
    /// Contents pages are *reserved* rather than rendered in place: their count follows
    /// from the number of lines the listing will carry, which the plan already settles, so
    /// the slots can be counted into the numbering before there is anything to put in
    /// them. Rendering them last, once every listed thing has a page, is what keeps the
    /// numbers a contents page prints and the numbers its own presence caused from
    /// chasing each other.
    private func layOut(_ plan: [PlanItem], packing: Bool, label: String, logger: Logger) -> [Page] {
        var pages: [Page] = []
        /// Plan index → the binder page that thing starts on. A thing that produced no
        /// page at all — a title that failed to render — is simply absent, and the
        /// contents leave it out rather than pointing at the page after it.
        var starts: [Int: Int] = [:]
        var reserved: [(slot: Int, count: Int, toc: TableOfContentsSpec, heading: String)] = []

        // A while loop rather than a for-in, because a packed binder takes its tunes a
        // *run* at a time: consecutive tunes are engraved as one document so that short
        // ones share pages (#48), and only that render knows how many items it consumed.
        var index = 0
        while index < plan.count {
            switch plan[index] {
            case .titlePage(let title, let section, _):
                let before = pages.count
                append(title, to: &pages, section: section, label: label, logger: logger)
                if pages.count > before { starts[index] = before + 1 }
                index += 1

            case .contents(let toc, let heading):
                let count = tocRenderer.pageCount(forEntries: listing(plan, for: toc).count)
                starts[index] = pages.count + 1
                reserved.append((slot: pages.count, count: count, toc: toc, heading: heading))
                pages.append(contentsOf: repeatElement(.contents(entries: [], svg: ""), count: count))
                logger.debug("[BinderService] \(label): reserving \(count) page(s) from \(pages.count - count + 1) for '\(heading)'")
                index += 1

            case .tune:
                let length = Self.runLength(in: plan, from: index, packing: packing)
                let run = plan[index ..< index + length].compactMap { item -> Resolution? in
                    guard case .tune(let resolution) = item else { return nil }
                    return resolution
                }
                let engraved = engrave(run, firstPageNumber: pages.count + 1,
                                       label: label, logger: logger)
                for (offset, start) in engraved.starts.enumerated() {
                    if let start { starts[index + offset] = pages.count + start + 1 }
                }
                pages.append(contentsOf: engraved.pages)
                index += length
            }
        }

        for slot in reserved {
            let entries = listing(plan, for: slot.toc).compactMap { listed in
                starts[listed.item].map {
                    TableOfContentsRenderer.Entry(text: listed.text, level: listed.level, page: $0)
                }
            }
            let drawn: [TableOfContentsRenderer.Page]
            do {
                drawn = try tocRenderer.render(heading: slot.heading, entries: entries,
                                               pageCount: slot.count)
                logger.debug("[BinderService] \(label): '\(slot.heading)' lists \(entries.count) entr(ies) over \(drawn.count) page(s)")
            } catch {
                // The slot was counted into every page number after it, so it stays a
                // page: a blank contents page is a poor binder, but dropping it would
                // make every number the binder prints one too high.
                logger.error("[BinderService] \(label): '\(slot.heading)' failed to render — leaving its \(slot.count) reserved page(s) blank: \(error)")
                drawn = Array(repeating: tocRenderer.blankPage(), count: slot.count)
            }
            for (offset, page) in drawn.enumerated() where slot.slot + offset < pages.count {
                pages[slot.slot + offset] = .contents(entries: page.entries, svg: page.svg)
            }
        }
        return pages
    }

    /// The lines `toc` will carry, in binder order and without their page numbers.
    ///
    /// Read from the *plan* rather than from the spec, so the contents name what the
    /// binder actually holds: a tune that did not resolve is not in the plan and so is
    /// not in the listing (#47).
    ///
    /// A section is listed when its title page stands over tunes. A title page standing
    /// on its own — a cover, or a divider with nothing under it — introduces nothing, so
    /// nothing is what it is listed as. Tunes are set one level in under the sections
    /// they belong to, and flush left in a listing that has no section lines to indent
    /// them under — whether because `include:` left sections out, or because the binder
    /// has no titled sections to name.
    private func listing(_ plan: [PlanItem], for toc: TableOfContentsSpec) -> [ListedItem] {
        let namesSections = toc.listsSections && plan.contains {
            if case .titlePage(_, _, let listed) = $0 { listed } else { false }
        }
        let tuneLevel = namesSections ? 1 : 0
        return plan.enumerated().compactMap { index, item in
            switch item {
            case .titlePage(let title, _, let listed):
                guard listed, toc.listsSections else { return nil }
                return ListedItem(item: index, level: 0, text: title.oneLine)
            case .tune(let resolution):
                guard toc.listsTunes else { return nil }
                return ListedItem(item: index, level: tuneLevel, text: resolution.displayName)
            case .contents:
                return nil
            }
        }
    }

    /// Engraves one title page and appends it, or logs why it could not be drawn.
    ///
    /// A binder missing a title page is still a usable binder, so a title that fails to
    /// render costs a page rather than the whole build.
    private func append(
        _ title: BinderTitle,
        to pages: inout [Page],
        section: Int,
        label: String,
        logger: Logger
    ) {
        do {
            pages.append(.titlePage(title: title, svg: try titleRenderer.render(title: title)))
            logger.debug("[BinderService] \(label): adding title page '\(title.display)' for section \(section + 1)")
        } catch {
            logger.error("[BinderService] \(label): title page '\(title.display)' failed to render — omitting it: \(error)")
        }
    }

    // MARK: - Official binder assembly

    /// What assembling one official binder produced.
    struct Assembly: Sendable {
        /// Where the binder PDF was written.
        let url: URL
        /// Pages in the finished binder, title pages included.
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
        logger.info("[BinderService] \(label): assembling '\(binder.name)' — branch '\(branch)', \(spec.sections.count) section(s), \(spec.entries.count) entr(ies)\(spec.pack ? ", packed" : "")")

        let binderPages = try await pages(for: spec, label: label, db: db, logger: logger)
        let resolved = Set(binderPages.flatMap(\.slugs))
        guard resolved.count > 0 else {
            throw Abort(.unprocessableEntity,
                        reason: "no tune in '\(binder.name)' resolved to any pages")
        }

        var missing: [String] = []
        for entry in spec.entries where !resolved.contains(entry.tuneSlug) && !missing.contains(entry.tuneSlug) {
            missing.append(entry.tuneSlug)
        }

        let pdfData = try Self.convert(binderPages.map(\.source), logger: logger)
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
    ///
    /// Each page is bound at the size CeolKit engraved it, landscape tunes included, which
    /// is what `ConversionOptions.engravedPages(logger:)` is for (#62). A binder therefore
    /// carries mixed page sizes, as every Gen.1 binder did.
    private static func convert(_ sources: [SVGSource], logger: Logger) throws -> Data {
        let converter = SVGPDFConverter(options: .engravedPages(logger: logger))
        return try converter.makePDF(sources: sources).pdfData
    }

    // MARK: - Resolution

    /// One entry, and what its pages can be engraved from.
    private struct Resolution {
        let slug: String
        /// Whether the entry asked for this tune to open a page of its own (#48).
        /// Nothing to honour in a binder that does not pack, where it always does.
        let breaksBefore: Bool
        /// The tune's title, or its slug where the ABC gave none: what a table of
        /// contents names it as (#47).
        let displayName: String
        let partName: String
        /// The tune's ABC source, when the catalogue has one to re-engrave.
        let abcURL: URL?
        /// The pages the build produced for this part. Never empty: a part with no
        /// pages is a part the build never converted, and a binder skips it.
        let prebuiltPaths: [String]
        /// The title of the section the entry sits in, which a `${label}` footer mark
        /// prints (#67). `nil` in a section with no title page.
        var sectionName: String? = nil

        /// What the build's own pages lack, for a log saying they are being reused: they
        /// were engraved for the tune alone, not for its place in this binder.
        var prebuiltFooters: String {
            sectionName == nil
                ? "whose footers number from 1"
                : "whose footers number from 1 and name no section"
        }
    }

    /// The one set of pages a binder entry contributes, or `nil` when the tune cannot be
    /// found or none of its parts produced any.
    ///
    /// **An entry resolves to exactly one part, however many it names.** Per-part rendering
    /// is deferred past MVP (#20): every `Part` row of a tune points at the same `svgPaths`
    /// today — the full multi-voice score — so honouring a list of three parts would append
    /// that score three times. The builder no longer offers the choice (#24), but shared
    /// URLs and stored `BinderRequest`s written while it did still name every part, and this
    /// is where those become one tune in the binder again.
    ///
    /// The part is still resolved through a `Part` record rather than from the ABC alone:
    /// the build is the authority on whether a tune produced pages at all. Which part stands
    /// for the tune does not matter while they are identical; when #20 makes them differ,
    /// this is where the list comes back.
    private func resolve(
        _ entry: BinderEntry,
        branch: String,
        label: String,
        db: Database,
        logger: Logger
    ) async throws -> Resolution? {
        logger.debug("[BinderService] \(label): looking up tune '\(entry.tuneSlug)'")
        guard let tune = try await Tune.query(on: db)
            .filter(\.$branch.$id == branch)
            .filter(\.$slug == entry.tuneSlug)
            .first(),
            let tuneID = tune.id else {
            logger.warning("[BinderService] \(label): tune '\(entry.tuneSlug)' not found in branch '\(branch)' — skipping")
            return nil
        }
        let abcURL = tune.abcPath.map { URL(fileURLWithPath: $0) }
        // The catalogue's title comes from the ABC `T:` header, which a file need not
        // carry; the slug is the filename, which it always does.
        let titled = tune.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = titled.isEmpty ? entry.tuneSlug : titled

        // Named parts first, in the order the entry names them, so an entry that asks for
        // one particular part still gets that part's record. An entry that names none —
        // which is what an official binder always sends — falls back to the tune's parts
        // in name order, for a stable choice rather than whatever the database returns.
        let candidates: [Part]
        if entry.parts.isEmpty {
            candidates = try await Part.query(on: db)
                .filter(\.$tune.$id == tuneID)
                .sort(\.$name)
                .all()
        } else {
            let byName = try await Part.query(on: db)
                .filter(\.$tune.$id == tuneID)
                .filter(\.$name ~~ entry.parts)
                .all()
                .reduce(into: [String: Part]()) { $0[$1.name] = $1 }
            candidates = entry.parts.compactMap { byName[$0] }
            if entry.parts.count > 1 {
                logger.debug("[BinderService] \(label): entry '\(entry.tuneSlug)' names \(entry.parts.count) parts — taking the tune once (#20)")
            }
        }
        guard !candidates.isEmpty else {
            let named = entry.parts.isEmpty
                ? "has no parts on record"
                : "has none of the parts it names (\(entry.parts.joined(separator: ", ")))"
            logger.warning("[BinderService] \(label): tune '\(entry.tuneSlug)' \(named) — skipping")
            return nil
        }

        for part in candidates {
            let paths = part.svgPaths ?? []
            guard !paths.isEmpty else {
                logger.warning("[BinderService] \(label): part '\(part.name)' of '\(entry.tuneSlug)' has no SVG paths — skipping")
                continue
            }
            logger.debug("[BinderService] \(label): resolved \(paths.count) page(s) for '\(entry.tuneSlug)' / '\(part.name)'")
            return Resolution(slug: entry.tuneSlug, breaksBefore: entry.breaksBefore,
                              displayName: displayName, partName: part.name,
                              abcURL: abcURL, prebuiltPaths: paths)
        }

        logger.warning("[BinderService] \(label): no part of '\(entry.tuneSlug)' has any pages — skipping")
        return nil
    }

    /// How many consecutive plan items the run starting at `index` holds.
    ///
    /// One, unless the binder packs — an unpacked binder is a binder of one-tune runs,
    /// which is exactly the one-tune-per-page assembly every binder had before #48.
    ///
    /// A run stops at anything that is not a tune, because a title page and a table of
    /// contents each own a page anyway and so cost nothing as a boundary; at a tune whose
    /// entry asked to open a page of its own (`break: before`); and at a tune with no ABC
    /// on record, whose pages come from the build already committed to whole sheets and
    /// cannot be packed into anything.
    private static func runLength(in plan: [PlanItem], from index: Int, packing: Bool) -> Int {
        guard packing, case .tune(let first) = plan[index], first.abcURL != nil else { return 1 }
        var length = 1
        while index + length < plan.count,
              case .tune(let next) = plan[index + length],
              !next.breaksBefore, next.abcURL != nil {
            length += 1
        }
        return length
    }

    /// The pages for one run, engraved so the first of them prints `firstPageNumber`.
    ///
    /// Returns the pages and, per resolution, the offset within them of the page that
    /// tune opens on — or `nil` where it produced no pages at all. The offsets are what
    /// a table of contents is numbered from, and under packing they are the only record
    /// of where a tune landed: two tunes sharing a sheet share an offset.
    ///
    /// A run of more than one tune is engraved as one document. If that fails — for any
    /// of the reasons `TuneRunRenderer.Failure` names, or anything reading the sources
    /// threw — the run falls back to engraving its tunes one at a time, which is a
    /// thicker binder and not a wrong one.
    private func engrave(
        _ resolutions: [Resolution],
        firstPageNumber: Int,
        label: String,
        logger: Logger
    ) -> (pages: [Page], starts: [Int?]) {
        if resolutions.count > 1,
           let packed = pack(resolutions, firstPageNumber: firstPageNumber,
                             label: label, logger: logger) {
            return packed
        }
        var pages: [Page] = []
        var starts: [Int?] = []
        for resolution in resolutions {
            let engraved = engrave(resolution, firstPageNumber: firstPageNumber + pages.count,
                                   label: label, logger: logger)
            starts.append(engraved.isEmpty ? nil : pages.count)
            pages.append(contentsOf: engraved)
        }
        return (pages, starts)
    }

    /// Engraves a run as one packed document, or `nil` where it could not be.
    ///
    /// Every resolution in a run has an ABC source — `runLength(in:from:packing:)` will
    /// not put one without into a run of more than one — so a run that gets here and has
    /// none is a programming error rather than a binder's problem, and it declines.
    private func pack(
        _ resolutions: [Resolution],
        firstPageNumber: Int,
        label: String,
        logger: Logger
    ) -> (pages: [Page], starts: [Int?])? {
        let sources = resolutions.compactMap { resolution in
            resolution.abcURL.map {
                TuneRunRenderer.Source(slug: resolution.slug, url: $0, label: resolution.sectionName)
            }
        }
        let named = resolutions.map(\.slug).joined(separator: ", ")
        guard sources.count == resolutions.count else {
            logger.error("[BinderService] \(label): a run of \(named) reached packing without an ABC source for every tune — engraving them one to a page instead")
            return nil
        }

        do {
            let rendering = try runRenderer.render(sources, firstPageNumber: firstPageNumber)
            // Which tunes open which page, so a sheet two short tunes share names both.
            var opening: [Int: [String]] = [:]
            for (index, start) in rendering.starts.enumerated() {
                opening[start, default: []].append(resolutions[index].slug)
            }
            if !rendering.printsPageNumbers {
                logger.warning("[BinderService] \(label): one of \(named) asks for a footer that names neither $P nor ${pagenumber}, so some of these \(rendering.pages.count) page(s) print no page number — they are numbered from \(firstPageNumber), they just do not say so")
            }
            logger.debug("[BinderService] \(label): packed \(resolutions.count) tune(s) (\(named)) onto \(rendering.pages.count) page(s) from page \(firstPageNumber)")
            return (pages: rendering.pages.enumerated().map {
                        .tune(slugs: opening[$0.offset] ?? [], svg: $0.element)
                    },
                    starts: rendering.starts.map(Optional.some))
        } catch {
            logger.error("[BinderService] \(label): packing \(resolutions.count) tune(s) (\(named)) failed — engraving them one to a page instead: \(error)")
            return nil
        }
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
            logger.error("[BinderService] \(label): tune '\(resolution.slug)' has no ABC source on record — reusing the build's \(fallback.count) page(s), \(resolution.prebuiltFooters)")
            return fallback
        }

        do {
            let rendering = try tuneRenderer.render(abcAt: abcURL, firstPageNumber: firstPageNumber,
                                                    label: resolution.sectionName)
            guard !rendering.pages.isEmpty else {
                logger.error("[BinderService] \(label): re-engraving '\(resolution.slug)' from \(abcURL.path) produced no pages — reusing the build's \(fallback.count), \(resolution.prebuiltFooters)")
                return fallback
            }
            if !rendering.printsPageNumbers {
                logger.warning("[BinderService] \(label): '\(resolution.slug)' asks for a footer that names neither $P nor ${pagenumber}, so its \(rendering.pages.count) page(s) print no page number — they are numbered from \(firstPageNumber), they just do not say so")
            }
            logger.debug("[BinderService] \(label): engraved \(rendering.pages.count) page(s) of '\(resolution.slug)' / '\(resolution.partName)' from page \(firstPageNumber)")
            // Only the first page opens the tune; the rest carry the rest of it.
            return rendering.pages.enumerated().map {
                .tune(slugs: $0.offset == 0 ? [resolution.slug] : [], svg: $0.element)
            }
        } catch {
            logger.error("[BinderService] \(label): re-engraving '\(resolution.slug)' from \(abcURL.path) failed — reusing the build's \(fallback.count) page(s), \(resolution.prebuiltFooters): \(error)")
            return fallback
        }
    }
}
