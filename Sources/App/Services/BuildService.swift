import CeolKitParser
import CeolKitSVGRenderer
import Fluent
import Foundation
import SVGPDFKit
import Vapor

// MARK: - BuildService

/// Orchestrates the full build pipeline for one git branch:
///
///   1. Create a `Build` record (status: .running).
///   2. `git` sync via `GitService`.
///   3. Discover every `.abc` file in the working tree.
///   4. For each file: convert ABC → per-page SVGs (CeolKit) → PDF (SVGPDFKit).
///   5. Upsert the `Branch`, `Tune`, and `Part` catalogue records, then delete the
///      tunes whose `.abc` file has left the working tree.
///   6. Read `binders.yaml` and replace the branch's `BinderDefinition` records.
///   7. Assemble the official binders that file declares (via `BinderService`).
///   8. Optionally upload those binders — and only those — to Box (via `BoxService`).
///   9. Optionally post a Slack notification (via `SlackService`).
///  10. Update the `Build` record (status, log, files).
///
/// The build's *product* is the assembled binders, which is what `Build.files` lists and
/// what the Slack notification names. The per-tune PDFs are intermediates: they are what
/// the binders and the personalised builder are made from, and they stay on the server.
///
/// Status is `.failure` when the pipeline threw, `.partial` when it finished but
/// any per-file or distribution step failed, and `.success` only when nothing did.
///
/// The catalogue is reconciled rather than rebuilt: nothing is deleted until the
/// conversion loop has finished, so a build that throws part-way leaves the branch
/// serving the entries it already had instead of the fraction this build reached.
///
/// The service also removes branches (`removeBranch`). Builds and removals of the
/// same branch exclude each other, so a removal cannot race a build into recreating
/// the directories it just deleted.
actor BuildService {

    private let gitService: GitService
    private let boxService: BoxService
    private let slackService: SlackService
    private let binderService: BinderService
    private let musicWorkspaceURL: URL

    /// Builds currently running in this process, per branch. Webhook and manual
    /// syncs can overlap, hence a count rather than a set.
    private var buildsInFlight: [String: Int] = [:]
    /// Branches whose removal is in progress; builds for them are refused.
    private var removalsInFlight: Set<String> = []

    init(
        gitService: GitService,
        boxService: BoxService,
        slackService: SlackService,
        binderService: BinderService,
        musicWorkspacePath: String
    ) {
        self.gitService = gitService
        self.boxService = boxService
        self.slackService = slackService
        self.binderService = binderService
        self.musicWorkspaceURL = URL(fileURLWithPath: musicWorkspacePath, isDirectory: true)
    }

    // MARK: - Public API

    /// Runs a full build for `branch`: converts ABC files, uploads PDFs to Box,
    /// updates the catalogue, and posts a Slack notification.
    ///
    /// Never throws — all errors are caught, logged, and persisted to the
    /// `Build` record so the HTTP handler can return 202 immediately.
    func runBuild(branch: String, commitSha: String?, db: Database, logger: Logger) async {
        logger.info("[BuildService] Starting build for branch '\(branch)'")
        await _performBuild(
            branch: branch, commitSha: commitSha,
            db: db, logger: logger,
            uploadToBox: true, notifySlack: true
        )
    }

    /// Syncs the repository and updates the tune catalogue for `branch` without
    /// uploading to Box or posting a Slack notification.
    ///
    /// Use this to populate (or refresh) `Branch`, `Tune`, and `Part` records
    /// during development or before a full build has been triggered by a push.
    func syncCatalogue(branch: String, db: Database, logger: Logger) async {
        logger.info("[BuildService] Starting catalogue sync for branch '\(branch)'")
        await _performBuild(
            branch: branch, commitSha: nil,
            db: db, logger: logger,
            uploadToBox: false, notifySlack: false
        )
    }

    // MARK: - Core pipeline

    private func _performBuild(
        branch: String,
        commitSha: String?,
        db: Database,
        logger: Logger,
        uploadToBox: Bool,
        notifySlack: Bool
    ) async {
        guard beginBuild(branch: branch) else {
            logger.warning("[BuildService] Branch '\(branch)' is being removed; build not started")
            return
        }
        defer { endBuild(branch: branch) }

        // Ensure the Branch record exists before creating the Build (FK constraint).
        let branchRecord: Branch
        do {
            if let existing = try await Branch.find(branch, on: db) {
                branchRecord = existing
            } else {
                let fresh = Branch(name: branch)
                try await fresh.save(on: db)
                branchRecord = fresh
            }
        } catch {
            logger.error("[BuildService] Could not ensure Branch record for '\(branch)': \(error)")
            return
        }

        // Create the Build record up-front so it appears in the admin UI immediately.
        let build = Build()
        build.$branch.id = branch
        build.commitSha = commitSha
        build.status = .running
        build.files = []

        do {
            try await build.save(on: db)
        } catch {
            logger.error("[BuildService] Could not save initial Build record: \(error)")
            return
        }

        var log = uploadToBox ? "" : "[catalogue-sync] Box upload and Slack notification skipped.\n"
        /// The assembled official binders — what this build produced.
        var producedFiles: [String] = []
        /// Per-tune PDFs, counted for the log. They are intermediates, not products.
        var convertedTunes = 0
        // Steps that failed without aborting the build; any makes it `.partial`.
        var failedSteps = 0

        do {
            // ── git sync ────────────────────────────────────────────────────
            log += "[git] Syncing branch '\(branch)'…\n"
            let branchDir = try await gitService.sync(branch: branch, logger: logger)
            let sha = try await gitService.headSHA(in: branchDir)
            log += "[git] HEAD is \(sha)\n"

            // ── discover .abc files ─────────────────────────────────────────
            let abcFiles = try discoverABCFiles(in: branchDir)
            log += "[build] Found \(abcFiles.count) .abc file(s)\n"
            logger.info("[BuildService] \(abcFiles.count) .abc files in '\(branch)'")

            // ── convert each file ───────────────────────────────────────────
            let outputDir = outputDirectory(for: branch)
            try FileManager.default.createDirectory(at: outputDir,
                                                    withIntermediateDirectories: true)

            // One renderer for all files. Bagpipe-specific engraving is driven from
            // the ABC source itself (`%%ceolkit:pipeformat true`), not from config.
            let renderer = SVGRenderer(config: .init(pageSize: .letter))

            for abcURL in abcFiles {
                let stem = abcURL.deletingPathExtension().lastPathComponent
                log += "[convert] \(stem).abc\n"

                let abcContent = try String(contentsOf: abcURL, encoding: .utf8)

                // The parser's base directory is the ABC file's own directory so
                // `I:abc-include` references resolve relative to the source file.
                let parser = CeolKitParser(
                    for: abcURL.deletingLastPathComponent(),
                    fileResolver: CeolKitParser.defaultFileResolver
                )
                let parsed = parser.parse(abcContent, options: .default)
                let diagnostics = formatDiagnostics(parsed, stem: stem)
                log += diagnostics.text
                if diagnostics.errors > 0 {
                    // The pages will still be engraved, from a score CeolKit had to
                    // guess at. That is not a tune that built, so the build does not
                    // come out green over it.
                    logger.warning("[BuildService] \(stem).abc parsed with \(diagnostics.errors) error(s)")
                    failedSteps += 1
                }

                // CeolKit's SVG renderer returns one complete <svg>…</svg> document
                // per page. Write each to its own numbered file so SVGPDFKit can
                // render them as separate PDF pages.
                let pageStrings = try renderer.render(parsed.score)
                log += "[convert]   → \(pageStrings.count) page(s)\n"

                guard !pageStrings.isEmpty else {
                    log += "[convert]   ⚠ No SVG output for \(stem).abc — skipping PDF\n"
                    logger.warning("[BuildService] No SVG output for \(stem).abc; skipping")
                    failedSteps += 1
                    continue
                }

                var svgFiles: [URL] = []
                for (i, pageString) in pageStrings.enumerated() {
                    let pageURL = outputDir.appendingPathComponent(
                        String(format: "%@%03d.svg", stem, i))
                    try pageString.write(to: pageURL, atomically: true, encoding: .utf8)
                    svgFiles.append(pageURL)
                }

                let pdfURL = outputDir.appendingPathComponent("\(stem).pdf")
                try convertToPDF(svgFiles: svgFiles, outputURL: pdfURL)
                convertedTunes += 1

                // ── catalogue population ────────────────────────────────────
                do {
                    try await upsertCatalogueEntry(
                        branch: branch,
                        stem: stem,
                        abcPath: abcURL.path,
                        parsed: parsed,
                        pdfPath: pdfURL.path,
                        svgPaths: svgFiles.map(\.path),
                        db: db
                    )
                    log += "[catalogue] Upserted \(stem)\n"
                } catch {
                    log += "[catalogue] Upsert failed for \(stem): \(error)\n"
                    logger.warning("[BuildService] Catalogue upsert failed for \(stem): \(error)")
                    failedSteps += 1
                }
            }

            // ── reconcile the catalogue with the working tree ───────────────
            // The branch keeps the entries it had until this build has something
            // to put in their place, so a throw anywhere above leaves a stale
            // catalogue rather than a gutted one. What goes now is the tunes whose
            // `.abc` file has left the tree, and nothing else: a file that failed
            // to convert is still in the tree, so its entry survives as it was.
            do {
                let stems = Set(abcFiles.map { $0.deletingPathExtension().lastPathComponent })
                if stems.isEmpty {
                    // A tree with no music in it is far more likely to be a bad
                    // checkout than a branch that has genuinely lost every tune,
                    // and an empty catalogue is the damage this build exists not
                    // to do. Keep the rows; say so loudly. `removeBranch` is how
                    // a branch's catalogue is meant to end.
                    let kept = try await Tune.query(on: db).filter(\.$branch.$id == branch).count()
                    if kept > 0 {
                        log += "[catalogue] ⚠ No .abc files in the tree; keeping the "
                        log += "\(kept) existing catalogue row(s) rather than emptying the catalogue\n"
                        logger.warning("[BuildService] '\(branch)' has no .abc files; kept \(kept) catalogue row(s)")
                        failedSteps += 1
                    }
                } else {
                    let pruned = try await pruneCatalogue(branch: branch, keeping: stems, db: db)
                    if !pruned.tunes.isEmpty {
                        log += "[catalogue] Removed \(pruned.tunes.count) tune(s) no longer in the tree "
                        log += "(\(pruned.parts) part(s)): \(pruned.tunes.joined(separator: ", "))\n"
                        logger.info("[BuildService] Pruned \(pruned.tunes.count) tune(s) from '\(branch)'")
                    }
                }
            } catch {
                log += "[catalogue] Pruning removed tunes failed: \(error)\n"
                logger.warning("[BuildService] Catalogue pruning failed for '\(branch)': \(error)")
                failedSteps += 1
            }

            // ── official binder definitions ─────────────────────────────────
            // After conversion, so entries are checked against this build's catalogue.
            let definitions = await refreshBinderDefinitions(
                branch: branch, branchDir: branchDir, db: db, log: &log, logger: logger)
            failedSteps += definitions.failures

            // ── assemble the official binders ───────────────────────────────
            // These are the build's product: what `Build.files` lists, what Slack names,
            // and the only thing that goes to Box.
            let assembly = await assembleOfficialBinders(
                branch: branch, binders: definitions.binders, db: db, log: &log, logger: logger)
            failedSteps += assembly.failures
            producedFiles = assembly.binders.map(\.filename)

            // ── Box upload (skipped for catalogue sync) ─────────────────────
            var boxFolderURL: String?
            var caughtUp: [String] = []
            if uploadToBox {
                let upload = await uploadBinders(
                    assembly.binders, branch: branch, db: db, log: &log, logger: logger)
                failedSteps += upload.failures
                boxFolderURL = upload.folderID.map(BoxService.folderURL(id:))
                caughtUp = upload.retried
            }

            // ── update Branch record timestamps ─────────────────────────────
            branchRecord.lastBuilt = Date()
            branchRecord.headSha = sha
            try await branchRecord.save(on: db)
            log += "[db] Branch '\(branch)' updated\n"

            // ── Slack notification (skipped for catalogue sync) ──────────────
            // Sent with the status as it stands; a failed post can't report
            // itself to Slack, but it still downgrades the recorded status.
            if notifySlack {
                do {
                    try await slackService.postBuildNotification(
                        branch: branch,
                        status: failedSteps == 0 ? .success : .partial,
                        files: producedFiles,
                        boxFolderURL: boxFolderURL,
                        alsoUploaded: caughtUp)
                } catch {
                    log += "[slack] Notification failed: \(error)\n"
                    logger.warning("[BuildService] Slack notification failed: \(error)")
                    failedSteps += 1
                }
            }

            // ── record outcome ──────────────────────────────────────────────
            if failedSteps == 0 {
                build.status = .success
            } else {
                build.status = .partial
                log += "[build] \(failedSteps) step(s) failed; build marked partial\n"
            }
            build.files = producedFiles
            build.log = log
            try await build.save(on: db)
            logger.info("[BuildService] Build \(build.id!) finished \(build.status.rawValue) (\(convertedTunes) tune(s) converted, \(producedFiles.count) binder(s) assembled, \(failedSteps) failed step(s))")

        } catch {
            log += "[error] \(error)\n"
            logger.error("[BuildService] Build failed: \(error)")

            build.status = .failure
            build.files = producedFiles
            build.log = log
            try? await build.save(on: db)

            if notifySlack {
                do {
                    try await slackService.postBuildNotification(
                        branch: branch, status: .failure, files: [])
                } catch {
                    logger.warning("[BuildService] Slack failure notification failed: \(error)")
                }
            }
        }
    }

    // MARK: - Build/removal exclusion

    /// Records a build of `branch` as started, unless the branch is being removed.
    /// Synchronous, so the check and the claim cannot be split by a suspension.
    func beginBuild(branch: String) -> Bool {
        guard !removalsInFlight.contains(branch) else { return false }
        buildsInFlight[branch, default: 0] += 1
        return true
    }

    func endBuild(branch: String) {
        if let count = buildsInFlight[branch], count > 1 {
            buildsInFlight[branch] = count - 1
        } else {
            buildsInFlight[branch] = nil
        }
    }

    // MARK: - Branch removal

    /// Top-level workspace directories that belong to no branch. A branch with one
    /// of these names would have its checkout directory collide with them.
    static let reservedWorkspaceNames: Set<String> = ["output", "binders"]

    /// Deletes everything the server derived from `branch`: its `binder_definitions`,
    /// `parts`, `tunes`, `builds` and `branches` rows (in one transaction), then its
    /// git checkout and its SVG/PDF output directory.
    ///
    /// Box is never touched. Removing rows without directories, or directories
    /// without rows, succeeds; a branch with neither is `404`.
    ///
    /// - Throws: `Abort(.badRequest)` for a name that could escape the workspace,
    ///   `Abort(.conflict)` while the branch is being built or already being removed.
    func removeBranch(_ branch: String, db: any Database, logger: Logger) async throws -> BranchRemovalSummary {
        let directories = try branchDirectories(for: branch)

        guard buildsInFlight[branch] == nil else {
            throw Abort(.conflict, reason: "A build of branch '\(branch)' is running. Try again when it finishes.")
        }
        guard removalsInFlight.insert(branch).inserted else {
            throw Abort(.conflict, reason: "Branch '\(branch)' is already being removed.")
        }
        defer { removalsInFlight.remove(branch) }

        let rows = try await db.transaction { tx in
            let tuneIDs = try await Tune.query(on: tx)
                .filter(\.$branch.$id == branch)
                .all(\.$id)
            // Parts would cascade from tunes, but deleting them explicitly gives the count.
            let parts = try await Part.query(on: tx).filter(\.$tune.$id ~~ tuneIDs).count()
            try await Part.query(on: tx).filter(\.$tune.$id ~~ tuneIDs).delete()

            let tunes = tuneIDs.count
            try await Tune.query(on: tx).filter(\.$branch.$id == branch).delete()

            let builds = try await Build.query(on: tx).filter(\.$branch.$id == branch).count()
            try await Build.query(on: tx).filter(\.$branch.$id == branch).delete()

            let binders = try await BinderDefinition.query(on: tx).filter(\.$branch.$id == branch).count()
            try await BinderDefinition.query(on: tx).filter(\.$branch.$id == branch).delete()

            let uploads = try await BoxUpload.query(on: tx).filter(\.$branch.$id == branch).count()
            try await BoxUpload.query(on: tx).filter(\.$branch.$id == branch).delete()

            let branchRow = try await Branch.find(branch, on: tx)
            try await branchRow?.delete(on: tx)

            return (tunes: tunes, parts: parts, builds: builds, binders: binders,
                    uploads: uploads, hadBranch: branchRow != nil)
        }

        let fm = FileManager.default
        var removed: [String] = []
        var bytes: Int64 = 0
        for (relative, url) in directories where fm.fileExists(atPath: url.path) {
            bytes += Self.regularFileBytes(under: url)
            try fm.removeItem(at: url)
            removed.append(relative)
        }

        guard rows.hadBranch || rows.tunes + rows.builds + rows.binders + rows.uploads > 0 || !removed.isEmpty else {
            throw Abort(.notFound, reason: "No branch '\(branch)' in the database or the workspace.")
        }

        let summary = BranchRemovalSummary(
            branch: branch, tunes: rows.tunes, parts: rows.parts, builds: rows.builds,
            binderDefinitions: rows.binders, boxUploads: rows.uploads,
            directories: removed, bytes: bytes)
        logger.notice("[BuildService] Removed branch '\(branch)': \(summary.tunes) tune(s), \(summary.parts) part(s), \(summary.builds) build(s), \(summary.binderDefinitions) binder definition(s); deleted \(removed.isEmpty ? "no directories" : removed.joined(separator: ", ")) (\(bytes) bytes)")
        return summary
    }

    /// The per-page SVGs and per-tune PDFs for `branch`.
    private func outputDirectory(for branch: String) -> URL {
        musicWorkspaceURL
            .appendingPathComponent("output", isDirectory: true)
            .appendingPathComponent(branch, isDirectory: true)
    }

    /// The assembled official binders for `branch`.
    ///
    /// A subdirectory of the branch's output directory rather than the directory itself:
    /// a binder's `output:` filename is chosen by the pipe major and a tune's is the
    /// `.abc` stem, so `2026_binder.pdf` sitting beside the tunes would silently
    /// overwrite — or be overwritten by — a tune slugged `2026_binder`. Nested inside
    /// `output/<branch>`, it still goes when `removeBranch` deletes that directory.
    func binderOutputDirectory(for branch: String) -> URL {
        outputDirectory(for: branch).appendingPathComponent("binders", isDirectory: true)
    }

    /// The checkout and output directories for `branch`, keyed by workspace-relative
    /// path, after checking the name cannot reach anything outside them.
    ///
    /// The name comes from a URL and is about to be handed to `removeItem`, so it
    /// must be one or more ordinary path components, must not collide with a
    /// reserved workspace directory, and must resolve strictly inside the workspace.
    func branchDirectories(for branch: String) throws -> [(String, URL)] {
        let components = branch.split(separator: "/", omittingEmptySubsequences: false)
        let unsafe = branch.isEmpty
            || branch.contains("\0")
            || branch.contains("\\")
            || components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            || Self.reservedWorkspaceNames.contains(String(components[0]))
        guard !unsafe else {
            throw Abort(.badRequest, reason: "'\(branch)' is not a removable branch name.")
        }

        let candidates = [
            (branch, musicWorkspaceURL.appendingPathComponent(branch, isDirectory: true)),
            ("output/\(branch)", outputDirectory(for: branch)),
        ]
        // Belt and braces: the component checks above should already guarantee this.
        let workspacePath = musicWorkspaceURL.standardizedFileURL.path
        for (_, url) in candidates {
            guard url.standardizedFileURL.path.hasPrefix(workspacePath + "/") else {
                throw Abort(.badRequest, reason: "'\(branch)' resolves outside the music workspace.")
            }
        }
        return candidates
    }

    private static func regularFileBytes(under directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Catalogue population

    /// Upserts the `Tune` and `Part` records for one converted ABC file, and drops
    /// the parts that file no longer declares.
    ///
    /// Takes the `ParseResult` produced for rendering rather than the raw ABC
    /// text: the file has already been parsed once, and CeolKit's score model
    /// carries the title and voice names the catalogue needs.
    ///
    /// One transaction per file, so an entry is never left half-written: a tune
    /// either has the parts this build engraved for it or the ones the last build
    /// did, and no member is offered a part whose PDF was never made.
    func upsertCatalogueEntry(
        branch: String,
        stem: String,
        abcPath: String,
        parsed: ParseResult,
        pdfPath: String,
        svgPaths: [String],
        db: Database
    ) async throws {
        let entry = CatalogueExtractor.extract(from: parsed)

        try await db.transaction { tx in
            // Upsert Tune
            let tune: Tune
            if let existing = try await Tune.query(on: tx)
                .filter(\.$branch.$id == branch)
                .filter(\.$slug == stem)
                .first() {
                existing.title = entry.title
                existing.subtitle = entry.subtitle
                existing.abcPath = abcPath
                try await existing.save(on: tx)
                tune = existing
            } else {
                let fresh = Tune()
                fresh.$branch.id = branch
                fresh.slug = stem
                fresh.title = entry.title
                fresh.subtitle = entry.subtitle
                fresh.abcPath = abcPath
                try await fresh.save(on: tx)
                tune = fresh
            }

            let tuneID = try tune.requireID()

            // Upsert Parts
            for partName in entry.parts {
                if let existing = try await Part.query(on: tx)
                    .filter(\.$tune.$id == tuneID)
                    .filter(\.$name == partName)
                    .first() {
                    existing.pdfPath = pdfPath
                    existing.svgPaths = svgPaths
                    try await existing.save(on: tx)
                } else {
                    let part = Part()
                    part.$tune.id = tuneID
                    part.name = partName
                    part.pdfPath = pdfPath
                    part.svgPaths = svgPaths
                    try await part.save(on: tx)
                }
            }

            // A renamed or deleted voice used to disappear with the wholesale
            // clear that ran before conversion. Nothing clears now, so the parts
            // this file has stopped declaring have to go here, or a binder would
            // keep offering a part that no longer exists in the arrangement.
            try await Part.query(on: tx)
                .filter(\.$tune.$id == tuneID)
                .filter(\.$name !~ entry.parts)
                .delete()
        }
    }

    /// Deletes the branch's tunes — and their parts — whose slug is not in
    /// `slugs`, i.e. whose `.abc` file is no longer in the working tree.
    ///
    /// Runs once conversion has finished, in one transaction, and touches nothing
    /// a build might still be writing. A tune that is in the tree but failed to
    /// convert keeps its existing row: the file is still there, so the entry is
    /// stale, not gone.
    ///
    /// - Returns: The slugs removed, in order, and how many parts went with them.
    func pruneCatalogue(
        branch: String,
        keeping slugs: Set<String>,
        db: any Database
    ) async throws -> (tunes: [String], parts: Int) {
        try await db.transaction { tx in
            let stale = try await Tune.query(on: tx)
                .filter(\.$branch.$id == branch)
                .all()
                .filter { !slugs.contains($0.slug) }
            let staleIDs = try stale.map { try $0.requireID() }
            guard !staleIDs.isEmpty else { return (tunes: [], parts: 0) }

            // Parts would cascade from tunes, but deleting them explicitly gives
            // the count — as `removeBranch` does.
            let parts = try await Part.query(on: tx).filter(\.$tune.$id ~~ staleIDs).count()
            try await Part.query(on: tx).filter(\.$tune.$id ~~ staleIDs).delete()
            try await Tune.query(on: tx).filter(\.$id ~~ staleIDs).delete()

            return (tunes: stale.map(\.slug).sorted(), parts: parts)
        }
    }

    // MARK: - Official binder definitions

    /// Reads `binders.yaml`, logs any entries the catalogue cannot resolve, and
    /// replaces the branch's stored `BinderDefinition` records with the file's.
    ///
    /// A branch with no `binders.yaml` is not an error: it has no official binders
    /// yet. A file that cannot be used is a failed step, and — since the repository
    /// is the source of truth — leaves the branch with no stored definitions rather
    /// than stale ones.
    ///
    /// - Returns: The binders the file declares — empty when it is absent or unusable —
    ///   and the number of failed steps (0 or more) to add to the build's count.
    private func refreshBinderDefinitions(
        branch: String,
        branchDir: URL,
        db: Database,
        log: inout String,
        logger: Logger
    ) async -> (binders: [OfficialBinder], failures: Int) {
        let fileName = BinderDefinitionLoader.fileName
        var failures = 0
        var binders: [OfficialBinder] = []

        do {
            if let file = try BinderDefinitionLoader.load(from: branchDir) {
                binders = file.binders
                log += "[binders] Read \(binders.count) binder definition(s) from \(fileName)\n"

                let slugs = try await Tune.query(on: db)
                    .filter(\.$branch.$id == branch)
                    .all()
                    .map(\.slug)
                let unresolved = BinderDefinitionLoader.unresolvedEntries(
                    in: file, catalogueSlugs: Set(slugs))
                for entry in unresolved {
                    log += "[binders]   ⚠ \"\(entry.binder)\" › \"\(entry.section)\": "
                    log += "no tune '\(entry.tune)' in the catalogue\n"
                }
                if !unresolved.isEmpty {
                    logger.warning("[BuildService] \(unresolved.count) unresolved tune(s) in \(fileName) on '\(branch)'")
                    failures += 1
                }
            } else {
                log += "[binders] No \(fileName) on '\(branch)'; no official binders defined\n"
            }
        } catch {
            log += "[binders] ✗ \(fileName) rejected: \(error)\n"
            logger.warning("[BuildService] \(fileName) rejected on '\(branch)': \(error)")
            failures += 1
        }

        do {
            try await BinderDefinitionLoader.replaceDefinitions(for: branch, with: binders, on: db)
            log += "[db] Stored \(binders.count) binder definition(s) for '\(branch)'\n"
        } catch {
            log += "[db] Storing binder definitions failed: \(error)\n"
            logger.warning("[BuildService] Storing binder definitions failed: \(error)")
            failures += 1
        }
        return (binders, failures)
    }

    // MARK: - Official binder assembly

    /// One assembled official binder.
    struct AssembledBinder: Sendable {
        /// The `output:` filename the binder declared, which is also its name in Box.
        let filename: String
        /// Where it was written on disk.
        let url: URL
    }

    /// Assembles every binder `binders.yaml` declared, writing each to the branch's
    /// binder output directory.
    ///
    /// One binder failing does not stop the others: a band with two binders and one
    /// broken tune should still get the binder that is fine. Each failure is a failed
    /// step, so the build comes out `partial` rather than green.
    ///
    /// A tune the binder names but the catalogue could not supply is logged per binder,
    /// not just once per file: `refreshBinderDefinitions` says the slug is unknown, and
    /// this says which binder went to press without it.
    private func assembleOfficialBinders(
        branch: String,
        binders: [OfficialBinder],
        db: Database,
        log: inout String,
        logger: Logger
    ) async -> (binders: [AssembledBinder], failures: Int) {
        guard !binders.isEmpty else { return ([], 0) }

        let directory = binderOutputDirectory(for: branch)
        var assembled: [AssembledBinder] = []
        var failures = 0

        for binder in binders {
            do {
                let result = try await binderService.assemble(
                    binder, branch: branch, in: directory, db: db, logger: logger)
                log += "[binder] Assembled \(binder.output) — \(result.pageCount) page(s)\n"
                for slug in result.missing {
                    log += "[binder]   ⚠ \(binder.output) is missing '\(slug)': it produced no pages\n"
                }
                if !result.missing.isEmpty {
                    logger.warning("[BuildService] \(binder.output) assembled without \(result.missing.count) tune(s)")
                    failures += 1
                }
                do {
                    // The record of this file's journey to Box, written before any
                    // attempt on it: a build that dies mid-upload still leaves the next
                    // one something to reconcile from.
                    _ = try await BoxUpload.record(
                        branch: branch, filename: binder.output, url: result.url, on: db)
                } catch {
                    log += "[binder]   ⚠ Could not record \(binder.output) for upload: \(error)\n"
                    logger.warning("[BuildService] Recording \(binder.output) for upload failed: \(error)")
                    failures += 1
                }
                assembled.append(AssembledBinder(filename: binder.output, url: result.url))
            } catch {
                log += "[binder] ✗ \(binder.output) could not be assembled: \(error)\n"
                logger.warning("[BuildService] Assembling \(binder.output) for '\(branch)' failed: \(error)")
                failures += 1
            }
        }
        return (assembled, failures)
    }

    // MARK: - Box upload

    /// Uploads the assembled binders to the branch's year folder in Box.
    ///
    /// Only these go to Box (C5): the per-tune PDFs are intermediates the binders are
    /// made from, and a personalised binder is downloaded from TNG itself. One binder
    /// failing does not stop the next — a band with two binders should get the one that
    /// is fine — and every failure is a failed step, so a build that reached Box with
    /// none of its binders cannot come out green.
    ///
    /// Before returning, it catches up on any binder an earlier build assembled but
    /// could not send (O6) — see `retryOutstandingUploads`.
    ///
    /// - Returns: The ID of the year folder the binders went to, the binders held over
    ///   from earlier builds that went up with them, and the number of failed uploads.
    private func uploadBinders(
        _ binders: [AssembledBinder],
        branch: String,
        db: Database,
        log: inout String,
        logger: Logger
    ) async -> (folderID: String?, retried: [String], failures: Int) {
        var folderID: String?
        var failures = 0

        if binders.isEmpty {
            log += "[box] No binders to upload\n"
        }
        for binder in binders {
            do {
                folderID = try await boxService.upload(pdf: binder.url, forBranch: branch)
                log += "[box] Uploaded \(binder.filename)\n"
                await markUploaded(branch: branch, filename: binder.filename, db: db, logger: logger)
            } catch {
                log += "[box] ✗ Upload failed for \(binder.filename): \(error)\n"
                logger.warning("[BuildService] Box upload failed for \(binder.filename): \(error)")
                await markFailed(branch: branch, filename: binder.filename,
                                 error: error, db: db, logger: logger)
                failures += 1
            }
        }

        let caughtUp = await retryOutstandingUploads(
            branch: branch, excluding: Set(binders.map(\.filename)),
            db: db, log: &log, logger: logger)
        folderID = folderID ?? caughtUp.folderID
        failures += caughtUp.failures
        return (folderID, caughtUp.uploaded, failures)
    }

    /// Uploads the binders of `branch` that an earlier build assembled but could not
    /// send, skipping the ones this build has just dealt with.
    ///
    /// This is O6's "retry on the next build", and it runs here rather than before
    /// conversion for a reason: a binder this build is about to reassemble does not want
    /// last week's bytes pushed ahead of it, and a build that fails before assembly has
    /// no working Box session to retry through anyway.
    ///
    /// A pending file that is gone, or whose bytes are no longer the ones the row
    /// describes, is dropped rather than uploaded: something later rebuilt it, and
    /// uploading what is on disk now under a row that means something else would put
    /// the wrong version in Box.
    private func retryOutstandingUploads(
        branch: String,
        excluding handled: Set<String>,
        db: Database,
        log: inout String,
        logger: Logger
    ) async -> (folderID: String?, uploaded: [String], failures: Int) {
        let outstanding: [BoxUpload]
        do {
            outstanding = try await BoxUpload.outstanding(for: branch, on: db)
                .filter { !handled.contains($0.filename) }
        } catch {
            log += "[box] Could not check for outstanding uploads: \(error)\n"
            logger.warning("[BuildService] Reading outstanding uploads for '\(branch)' failed: \(error)")
            return (nil, [], 1)
        }
        guard !outstanding.isEmpty else { return (nil, [], 0) }

        log += "[box] \(outstanding.count) binder(s) held over from an earlier build\n"
        var folderID: String?
        var uploaded: [String] = []
        var failures = 0

        for row in outstanding {
            let url = URL(fileURLWithPath: row.localPath)
            guard FileManager.default.fileExists(atPath: row.localPath),
                  let hash = try? BoxUpload.hash(of: url), hash == row.contentHash else {
                log += "[box]   \(row.filename) is no longer on disk as assembled; dropping it\n"
                logger.info("[BuildService] Dropping stale outstanding upload \(row.filename) for '\(branch)'")
                try? await row.delete(on: db)
                continue
            }

            do {
                folderID = try await boxService.upload(pdf: url, forBranch: branch)
                log += "[box]   Uploaded \(row.filename), held over from an earlier build\n"
                row.uploadedAt = Date()
                row.lastError = nil
                row.attempts += 1
                try await row.save(on: db)
                uploaded.append(row.filename)
            } catch {
                log += "[box]   ✗ \(row.filename) failed again: \(error)\n"
                logger.warning("[BuildService] Retrying \(row.filename) for '\(branch)' failed: \(error)")
                await markFailed(branch: branch, filename: row.filename,
                                 error: error, db: db, logger: logger)
                failures += 1
            }
        }
        return (folderID, uploaded, failures)
    }

    /// Stamps a binder as having reached Box.
    ///
    /// Bookkeeping failures are logged but do not fail the build: the binder *is* in
    /// Box. The cost is that the next build may upload it a second time, which Box
    /// records as a new version of the same file and nobody has to clean up.
    private func markUploaded(branch: String, filename: String, db: Database, logger: Logger) async {
        do {
            guard let row = try await BoxUpload.query(on: db)
                .filter(\.$branch.$id == branch)
                .filter(\.$filename == filename)
                .first() else { return }
            row.uploadedAt = Date()
            row.lastError = nil
            row.attempts += 1
            try await row.save(on: db)
        } catch {
            logger.warning("[BuildService] Could not record \(filename) as uploaded: \(error)")
        }
    }

    /// Records why a binder did not reach Box, so the next build has something to
    /// retry and the operator has something to read.
    private func markFailed(branch: String, filename: String, error: any Error,
                            db: Database, logger: Logger) async {
        do {
            guard let row = try await BoxUpload.query(on: db)
                .filter(\.$branch.$id == branch)
                .filter(\.$filename == filename)
                .first() else { return }
            row.lastError = "\(error)"
            row.attempts += 1
            try await row.save(on: db)
        } catch {
            logger.warning("[BuildService] Could not record the failed upload of \(filename): \(error)")
        }
    }

    // MARK: - File discovery

    private func discoverABCFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "abc" }
            .sorted { $0.path < $1.path }
    }

    // MARK: - Parser diagnostics

    /// Renders CeolKit parse diagnostics as build-log lines, and counts the errors
    /// among them.
    ///
    /// Diagnostics replace the stdout/stderr that the previous `abcm2ps`-backed
    /// converter emitted, so they are the operator's only window into a source
    /// file that parsed badly. `info`-severity entries are dropped to keep the
    /// log readable.
    private func formatDiagnostics(_ parsed: ParseResult, stem: String) -> (text: String, errors: Int) {
        var out = ""
        var errors = 0
        for diagnostic in parsed.diagnostics {
            let label: String
            switch diagnostic.severity {
            case .error:   label = "✗ error"; errors += 1
            case .warning: label = "⚠ warning"
            case .info:    continue
            }
            let source = diagnostic.source
            let file = source.file?.lastPathComponent ?? "\(stem).abc"
            out += "[parse]   \(label) \(file):\(source.line):\(source.column): "
            out += "\(diagnostic.message) [\(diagnostic.code.rawValue)]\n"
            if let hint = diagnostic.hint {
                out += "[parse]     hint: \(hint)\n"
            }
        }
        return (out, errors)
    }

    // MARK: - PDF conversion

    private func convertToPDF(svgFiles: [URL], outputURL: URL) throws {
        let sources = svgFiles.map { SVGSource.fileURL($0) }
        let converter = SVGPDFConverter()
        try converter.convert(sources: sources, to: outputURL)
    }
}
