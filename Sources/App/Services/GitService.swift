import Foundation
import Vapor

// MARK: - Errors

enum GitError: Error, CustomStringConvertible {
    case failed(status: Int32, output: String)
    case gitNotFound

    var description: String {
        switch self {
        case .failed(let status, let output):
            return "git exited with status \(status):\n\(output)"
        case .gitNotFound:
            return "git executable not found at /usr/bin/git"
        }
    }
}

// MARK: - GitService

/// Manages per-branch working-directory checkouts of the `svpb-music` repository.
///
/// Each branch gets its own subdirectory under `workspaceBase`:
///   `<workspaceBase>/<branch>/`
///
/// On first sync the branch is cloned; on subsequent syncs the working copy
/// is hard-reset to `origin/<branch>` so it always reflects exactly what is
/// on the remote.
actor GitService {

    let repoURL: String
    let workspaceBase: URL

    init(repoURL: String, workspaceBase: URL) {
        self.repoURL = repoURL
        self.workspaceBase = workspaceBase
    }

    // MARK: - Public API

    /// Ensures the working copy for `branch` is up-to-date with the remote.
    ///
    /// - Returns: The URL of the checked-out branch directory.
    func sync(branch: String, logger: Logger) async throws -> URL {
        let branchDir = workspaceBase.appendingPathComponent(branch, isDirectory: true)
        let gitDir = branchDir.appendingPathComponent(".git", isDirectory: true)

        if FileManager.default.fileExists(atPath: gitDir.path) {
            // Existing checkout — fetch and hard-reset to keep it pristine.
            logger.info("[git] Fetching origin for branch '\(branch)' in \(branchDir.path)")
            let fetchOut = try await run(["fetch", "--prune", "origin"], in: branchDir)
            logger.debug("[git] fetch: \(fetchOut.trimmingCharacters(in: .whitespacesAndNewlines))")
            let resetOut = try await run(["reset", "--hard", "origin/\(branch)"], in: branchDir)
            logger.debug("[git] reset: \(resetOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            // First time — clone the branch into a fresh directory.
            logger.info("[git] Cloning '\(branch)' from \(repoURL) into \(branchDir.path)")
            try FileManager.default.createDirectory(at: workspaceBase,
                                                    withIntermediateDirectories: true)
            let cloneOut = try await run([
                "clone",
                "--branch", branch,
                "--single-branch",
                repoURL,
                branchDir.path,
            ], in: workspaceBase)
            logger.debug("[git] clone: \(cloneOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return branchDir
    }

    /// Returns the current HEAD commit SHA for an already-synced branch directory.
    func headSHA(in branchDir: URL) async throws -> String {
        let output = try await run(["rev-parse", "HEAD"], in: branchDir)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private helpers

    /// Runs a git command, capturing stdout+stderr.
    /// Throws `GitError.failed` if git exits non-zero.
    private func run(_ args: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = directory

            let outputPipe = Pipe()
            let errorPipe  = Pipe()
            process.standardOutput = outputPipe
            process.standardError  = errorPipe

            // Read both pipes inside the termination handler. By the time the
            // handler fires the process has exited, so all pipe data is available
            // and we can read sequentially without a deadlock risk for the small
            // output volumes that git produces (fetch/reset/clone/rev-parse).
            //
            // ⚠️  PIPE BUFFER LIMIT: macOS pipe buffers are typically 64 KB. If
            // a subprocess writes more than that without a reader consuming the
            // data, it will block waiting for the buffer to drain — and since we
            // only read *after* the process exits, we would deadlock. The git
            // commands used here (fetch, reset, clone, rev-parse) produce far
            // less than 64 KB of output, so this is safe. If you ever add a
            // command that could produce large output (e.g. `git log --all`,
            // `git diff`, large clone progress), replace this with an async
            // reader — use `FileHandle.bytes` (an `AsyncBytes` sequence) on
            // each pipe concurrently so the buffer never fills.
            process.terminationHandler = { proc in
                let output = String(
                    data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
                let error = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
                let combined = output + error
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: combined)
                } else {
                    continuation.resume(throwing: GitError.failed(
                        status: proc.terminationStatus, output: combined))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
