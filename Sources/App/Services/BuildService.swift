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
///   5. Optionally upload each PDF to Box (via `BoxService`).
///   6. Upsert the `Branch`, `Tune`, and `Part` catalogue records.
///   7. Read `binders.yaml` and replace the branch's `BinderDefinition` records.
///   8. Optionally post a Slack notification (via `SlackService`).
///   9. Update the `Build` record (status, log, files).
///
/// Status is `.failure` when the pipeline threw, `.partial` when it finished but
/// any per-file or distribution step failed, and `.success` only when nothing did.
///
/// The service also removes branches (`removeBranch`). Builds and removals of the
/// same branch exclude each other, so a removal cannot race a build into recreating
/// the directories it just deleted.
actor BuildService {

    private let gitService: GitService
    private let boxService: BoxService
    private let slackService: SlackService
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
        musicWorkspacePath: String
    ) {
        self.gitService = gitService
        self.boxService = boxService
        self.slackService = slackService
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
        var producedFiles: [String] = []
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

            // ── clear existing catalogue for this branch ─────────────────────
            // Delete all Tune records (Parts cascade-delete via FK constraint).
            try await Tune.query(on: db)
                .filter(\.$branch.$id == branch)
                .delete()
            log += "[catalogue] Cleared existing catalogue entries for '\(branch)'\n"
            logger.info("[BuildService] Cleared catalogue for '\(branch)'")

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
                log += formatDiagnostics(parsed, stem: stem)

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
                producedFiles.append("\(stem).pdf")

                // ── Box upload (skipped for catalogue sync) ─────────────────
                if uploadToBox {
                    do {
                        try await boxService.upload(pdf: pdfURL, forBranch: branch)
                        log += "[box] Uploaded \(stem).pdf\n"
                    } catch {
                        log += "[box] Upload failed for \(stem).pdf: \(error)\n"
                        logger.warning("[BuildService] Box upload failed for \(stem).pdf: \(error)")
                        failedSteps += 1
                    }
                }

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

            // ── official binder definitions ─────────────────────────────────
            // After conversion, so entries are checked against this build's catalogue.
            failedSteps += await refreshBinderDefinitions(
                branch: branch, branchDir: branchDir, db: db, log: &log, logger: logger)

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
                        files: producedFiles)
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
            logger.info("[BuildService] Build \(build.id!) finished \(build.status.rawValue) (\(producedFiles.count) files, \(failedSteps) failed step(s))")

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

            let branchRow = try await Branch.find(branch, on: tx)
            try await branchRow?.delete(on: tx)

            return (tunes: tunes, parts: parts, builds: builds, binders: binders,
                    hadBranch: branchRow != nil)
        }

        let fm = FileManager.default
        var removed: [String] = []
        var bytes: Int64 = 0
        for (relative, url) in directories where fm.fileExists(atPath: url.path) {
            bytes += Self.regularFileBytes(under: url)
            try fm.removeItem(at: url)
            removed.append(relative)
        }

        guard rows.hadBranch || rows.tunes + rows.builds + rows.binders > 0 || !removed.isEmpty else {
            throw Abort(.notFound, reason: "No branch '\(branch)' in the database or the workspace.")
        }

        let summary = BranchRemovalSummary(
            branch: branch, tunes: rows.tunes, parts: rows.parts, builds: rows.builds,
            binderDefinitions: rows.binders, directories: removed, bytes: bytes)
        logger.notice("[BuildService] Removed branch '\(branch)': \(summary.tunes) tune(s), \(summary.parts) part(s), \(summary.builds) build(s), \(summary.binderDefinitions) binder definition(s); deleted \(removed.isEmpty ? "no directories" : removed.joined(separator: ", ")) (\(bytes) bytes)")
        return summary
    }

    /// The per-page SVGs and per-tune PDFs for `branch`.
    private func outputDirectory(for branch: String) -> URL {
        musicWorkspaceURL
            .appendingPathComponent("output", isDirectory: true)
            .appendingPathComponent(branch, isDirectory: true)
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

    /// Upserts `Tune` and `Part` records for one converted ABC file.
    ///
    /// Takes the `ParseResult` produced for rendering rather than the raw ABC
    /// text: the file has already been parsed once, and CeolKit's score model
    /// carries the title and voice names the catalogue needs.
    private func upsertCatalogueEntry(
        branch: String,
        stem: String,
        abcPath: String,
        parsed: ParseResult,
        pdfPath: String,
        svgPaths: [String],
        db: Database
    ) async throws {
        let entry = CatalogueExtractor.extract(from: parsed)

        // Upsert Tune
        let tune: Tune
        if let existing = try await Tune.query(on: db)
            .filter(\.$branch.$id == branch)
            .filter(\.$slug == stem)
            .first() {
            existing.title = entry.title
            existing.subtitle = entry.subtitle
            existing.abcPath = abcPath
            try await existing.save(on: db)
            tune = existing
        } else {
            let fresh = Tune()
            fresh.$branch.id = branch
            fresh.slug = stem
            fresh.title = entry.title
            fresh.subtitle = entry.subtitle
            fresh.abcPath = abcPath
            try await fresh.save(on: db)
            tune = fresh
        }

        let tuneID = try tune.requireID()

        // Upsert Parts
        for partName in entry.parts {
            if let existing = try await Part.query(on: db)
                .filter(\.$tune.$id == tuneID)
                .filter(\.$name == partName)
                .first() {
                existing.pdfPath = pdfPath
                existing.svgPaths = svgPaths
                try await existing.save(on: db)
            } else {
                let part = Part()
                part.$tune.id = tuneID
                part.name = partName
                part.pdfPath = pdfPath
                part.svgPaths = svgPaths
                try await part.save(on: db)
            }
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
    /// - Returns: The number of failed steps (0 or more) to add to the build's count.
    private func refreshBinderDefinitions(
        branch: String,
        branchDir: URL,
        db: Database,
        log: inout String,
        logger: Logger
    ) async -> Int {
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
        return failures
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

    /// Renders CeolKit parse diagnostics as build-log lines.
    ///
    /// Diagnostics replace the stdout/stderr that the previous `abcm2ps`-backed
    /// converter emitted, so they are the operator's only window into a source
    /// file that parsed badly. `info`-severity entries are dropped to keep the
    /// log readable.
    private func formatDiagnostics(_ parsed: ParseResult, stem: String) -> String {
        var out = ""
        for diagnostic in parsed.diagnostics {
            let label: String
            switch diagnostic.severity {
            case .error:   label = "✗ error"
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
        return out
    }

    // MARK: - PDF conversion

    private func convertToPDF(svgFiles: [URL], outputURL: URL) throws {
        let sources = svgFiles.map { SVGSource.fileURL($0) }
        let converter = SVGPDFConverter()
        try converter.convert(sources: sources, to: outputURL)
    }
}
