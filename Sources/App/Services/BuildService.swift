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
///   4. For each file: convert ABC → per-page SVGs (ABCKit) → PDF (SVGPDFKit stub).
///   5. Upload each PDF to Box (via `BoxService`).
///   6. Upsert the `Branch` record (last_built, head_sha).
///   7. Post a Slack notification (via `SlackService`).
///   8. Update the `Build` record (status: .success or .failure, log, files).
///
/// **Catalogue population** (Tune/Part records) is Phase 2 work; a TODO marks
/// the place in the pipeline where it will be inserted.
///
/// **SVGPDFKit** converts the per-page SVGs into a single multi-page PDF via
/// `convertToPDF(svgFiles:outputURL:)`.
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

    /// Runs a full build for `branch` in the background.
    ///
    /// This method never throws — all errors are caught, logged, and persisted
    /// to the `Build` record so that the HTTP handler can return 202 immediately.
    func runBuild(branch: String, commitSha: String?, db: Database, logger: Logger) async {
        logger.info("[BuildService] Starting build for branch '\(branch)'")

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

        var log = ""
        var producedFiles: [String] = []

        do {
            // ── Step 2: git sync ────────────────────────────────────────────
            log += "[git] Syncing branch '\(branch)'…\n"
            let branchDir = try await gitService.sync(branch: branch, logger: logger)
            let sha = try await gitService.headSHA(in: branchDir)
            log += "[git] HEAD is \(sha)\n"

            // ── Step 3: discover .abc files ─────────────────────────────────
            let abcFiles = try discoverABCFiles(in: branchDir)
            log += "[build] Found \(abcFiles.count) .abc file(s)\n"
            logger.info("[BuildService] \(abcFiles.count) .abc files in '\(branch)'")

            // ── Step 4: convert each file ───────────────────────────────────
            let outputDir = musicWorkspaceURL
                .appendingPathComponent("output", isDirectory: true)
                .appendingPathComponent(branch, isDirectory: true)
            try FileManager.default.createDirectory(at: outputDir,
                                                    withIntermediateDirectories: true)
            let converter = ABCConverter(options: .init(
                outputFormat: .svg,
                pageSize: .letter,
                bagpipeFormat: true,
                svgOutputDirectory: outputDir.path + "/"
            ))

            for abcURL in abcFiles {
                let stem = abcURL.deletingPathExtension().lastPathComponent
                log += "[convert] \(stem).abc\n"

                let abcContent = try String(contentsOf: abcURL, encoding: .utf8)

                // ABCKit: ABC → per-page SVG files written into outputDir.
                let svgIndex = try await converter.convert(abcContent)
                let svgFiles = try collectSVGFiles(stem: stem, in: outputDir, index: svgIndex)
                log += "[convert]   → \(svgFiles.count) page(s)\n"

                // PDF output path.
                let pdfURL = outputDir.appendingPathComponent("\(stem).pdf")

                // SVGPDFKit: SVG pages → PDF.
                try convertToPDF(svgFiles: svgFiles, outputURL: pdfURL)

                producedFiles.append("\(stem).pdf")

                // ── Step 5: Box upload ──────────────────────────────────────
                do {
                    try await boxService.upload(pdf: pdfURL, forBranch: branch)
                    log += "[box] Uploaded \(stem).pdf\n"
                } catch {
                    // Box upload failure is non-fatal; the local PDF is retained
                    // for retry on the next build.
                    log += "[box] Upload failed for \(stem).pdf: \(error)\n"
                    logger.warning("[BuildService] Box upload failed for \(stem).pdf: \(error)")
                }

                // Phase 2 TODO: upsert Tune and Part catalogue records here,
                // parsing T:/V: fields from `abcContent`.
            }

            // ── Step 6: upsert Branch record ────────────────────────────────
            let branchRecord = try await Branch.find(branch, on: db) ?? Branch(name: branch)
            branchRecord.lastBuilt = Date()
            branchRecord.headSha = sha
            try await branchRecord.save(on: db)
            log += "[db] Branch '\(branch)' updated\n"

            // ── Step 7: Slack notification ──────────────────────────────────
            do {
                try await slackService.postBuildNotification(
                    branch: branch, status: .success, files: producedFiles)
            } catch {
                log += "[slack] Notification failed: \(error)\n"
                logger.warning("[BuildService] Slack notification failed: \(error)")
            }

            // ── Step 8: mark success ────────────────────────────────────────
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

            try? await slackService.postBuildNotification(
                branch: branch, status: .failure, files: [])
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

    // MARK: - SVG collection

    /// After ABCKit writes per-page SVG files into `directory`, this method
    /// collects them in page order.
    ///
    /// ABCKit (and the underlying abcm2ps) names per-page SVG files with a
    /// numeric suffix, e.g. `archie_beag001.svg`, `archie_beag002.svg`.
    /// Files are returned sorted by name so page order is preserved.
    private func collectSVGFiles(stem: String, in directory: URL, index: String) throws -> [URL] {
        let allSVGs = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "svg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // If abcm2ps wrote numbered files for this stem, use them.
        // Otherwise fall back to all SVGs in the directory.
        let stemFiles = allSVGs.filter {
            $0.lastPathComponent.hasPrefix(stem) && $0.pathExtension == "svg"
        }
        return stemFiles.isEmpty ? allSVGs : stemFiles
    }

    // MARK: - PDF conversion

    private func convertToPDF(svgFiles: [URL], outputURL: URL) throws {
        let sources = svgFiles.map { SVGSource.fileURL($0) }
        // Phase 2 TODO: set startingPageNumber per-tune once catalogue records
        // are being upserted so personal-binder page offsets can be applied.
        let converter = SVGPDFConverter()
        try converter.convert(sources: sources, to: outputURL)
    }
}
