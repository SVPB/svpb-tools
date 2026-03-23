import ABCKit
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
///   4. For each file: convert ABC → per-page SVGs (ABCKit) → PDF (SVGPDFKit).
///   5. Optionally upload each PDF to Box (via `BoxService`).
///   6. Upsert the `Branch`, `Tune`, and `Part` catalogue records.
///   7. Optionally post a Slack notification (via `SlackService`).
///   8. Update the `Build` record (status: .success or .failure, log, files).
actor BuildService {

    private let gitService: GitService
    private let boxService: BoxService
    private let slackService: SlackService
    private let musicWorkspaceURL: URL

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
            let outputDir = musicWorkspaceURL
                .appendingPathComponent("output", isDirectory: true)
                .appendingPathComponent(branch, isDirectory: true)
            try FileManager.default.createDirectory(at: outputDir,
                                                    withIntermediateDirectories: true)

            // One converter for all files; no svgOutputDirectory — ABCKit returns
            // all pages as concatenated SVG documents in the return value.
            let converter = ABCConverter(options: .init(
                outputFormat: .svg,
                pageSize: .letter,
                bagpipeFormat: true
            ))

            for abcURL in abcFiles {
                let stem = abcURL.deletingPathExtension().lastPathComponent
                log += "[convert] \(stem).abc\n"

                let abcContent = try String(contentsOf: abcURL, encoding: .utf8)

                // ABCKit returns all pages concatenated as individual <svg>…</svg>
                // documents. Split them and write each to its own numbered file so
                // SVGPDFKit can render them as separate PDF pages.
                let allPagesSVG = try await converter.convert(abcContent)
                let pageStrings = splitSVGPages(allPagesSVG)
                log += "[convert]   → \(pageStrings.count) page(s)\n"

                guard !pageStrings.isEmpty else {
                    log += "[convert]   ⚠ No SVG output for \(stem).abc — skipping PDF\n"
                    logger.warning("[BuildService] No SVG output for \(stem).abc; skipping")
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
                    }
                }

                // ── catalogue population ────────────────────────────────────
                do {
                    try await upsertCatalogueEntry(
                        branch: branch,
                        branchRecord: branchRecord,
                        stem: stem,
                        abcPath: abcURL.path,
                        abcContent: abcContent,
                        pdfPath: pdfURL.path,
                        svgPaths: svgFiles.map(\.path),
                        db: db
                    )
                    log += "[catalogue] Upserted \(stem)\n"
                } catch {
                    log += "[catalogue] Upsert failed for \(stem): \(error)\n"
                    logger.warning("[BuildService] Catalogue upsert failed for \(stem): \(error)")
                }
            }

            // ── update Branch record timestamps ─────────────────────────────
            branchRecord.lastBuilt = Date()
            branchRecord.headSha = sha
            try await branchRecord.save(on: db)
            log += "[db] Branch '\(branch)' updated\n"

            // ── Slack notification (skipped for catalogue sync) ──────────────
            if notifySlack {
                do {
                    try await slackService.postBuildNotification(
                        branch: branch, status: .success, files: producedFiles)
                } catch {
                    log += "[slack] Notification failed: \(error)\n"
                    logger.warning("[BuildService] Slack notification failed: \(error)")
                }
            }

            // ── mark success ────────────────────────────────────────────────
            build.status = .success
            build.files = producedFiles
            build.log = log
            try await build.save(on: db)
            logger.info("[BuildService] Build \(build.id!) succeeded (\(producedFiles.count) files)")

        } catch {
            log += "[error] \(error)\n"
            logger.error("[BuildService] Build failed: \(error)")

            build.status = .failure
            build.files = producedFiles
            build.log = log
            try? await build.save(on: db)

            if notifySlack {
                try? await slackService.postBuildNotification(
                    branch: branch, status: .failure, files: [])
            }
        }
    }

    // MARK: - Catalogue population

    /// Upserts `Tune` and `Part` records for one converted ABC file.
    private func upsertCatalogueEntry(
        branch: String,
        branchRecord: Branch,
        stem: String,
        abcPath: String,
        abcContent: String,
        pdfPath: String,
        svgPaths: [String],
        db: Database
    ) async throws {
        let parsed = ABCParser.parse(abcContent)

        // Upsert Tune
        let tune: Tune
        if let existing = try await Tune.query(on: db)
            .filter(\.$branch.$id == branch)
            .filter(\.$slug == stem)
            .first() {
            existing.title = parsed.title
            existing.abcPath = abcPath
            try await existing.save(on: db)
            tune = existing
        } else {
            let fresh = Tune()
            fresh.$branch.id = branch
            fresh.slug = stem
            fresh.title = parsed.title
            fresh.abcPath = abcPath
            try await fresh.save(on: db)
            tune = fresh
        }

        let tuneID = try tune.requireID()

        // Upsert Parts
        for partName in parsed.parts {
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

    // MARK: - SVG page splitting

    /// Splits a concatenated multi-page SVG string (as returned by ABCKit) into
    /// individual `<svg>…</svg>` documents, one per page.
    private func splitSVGPages(_ svg: String) -> [String] {
        svg.components(separatedBy: "</svg>")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0 + "</svg>" }
    }

    // MARK: - PDF conversion

    private func convertToPDF(svgFiles: [URL], outputURL: URL) throws {
        let sources = svgFiles.map { SVGSource.fileURL($0) }
        let converter = SVGPDFConverter()
        try converter.convert(sources: sources, to: outputURL)
    }
}
