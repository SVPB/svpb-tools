import Fluent
import Foundation
import Vapor

// MARK: - BinderCache

/// Keeps personal binders for a fixed number of days after they are built, then deletes
/// them (#83).
///
/// Every personal binder is written to `<musicWorkspace>/binders/<id>.pdf`, and before
/// this nothing ever removed one: every binder anyone had built sat on a 25 GB droplet
/// disk for good. A binder takes a minute to rebuild and nothing else, so the policy is a
/// plain lifetime counted from when it was built — one that can be printed next to the
/// link — rather than one counted from the last download, which nobody could plan around.
///
/// The lifetime is stamped on the row as `expiresAt` when the PDF is written, from the
/// period in force at that moment. Changing the period changes what later binders are
/// promised, never what an earlier one was told.
///
/// Each sweep deletes, once the period has passed:
///   - a binder's PDF and its `BinderRequest` row, at its `expiresAt`;
///   - a row with no `expiresAt` — one that failed, or that predates retention — at its
///     `createdAt` plus the current period;
///   - a file in the binders directory that no remaining row names, by its modification
///     time plus the current period.
///
/// Only the personal binders directory is touched. Official binders live under
/// `output/<branch>/binders/`, are overwritten by every build, and go with their branch.
///
/// In-process for the same reason as `BoxTokenKeepAlive`: an external timer is one more
/// thing to forget when the droplet is rebuilt.
struct BinderCache: LifecycleHandler {

    /// Days a binder is kept when neither an admin nor `BINDER_RETENTION_DAYS` says otherwise.
    static let defaultRetentionDays = 14

    /// How long to wait after boot before the first sweep.
    static let initialDelay: Duration = .seconds(90)

    /// Time between sweeps. A binder outliving its expiry by up to an hour costs nothing.
    static let sweepInterval: Duration = .seconds(60 * 60)

    // MARK: - Lifecycle

    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    func didBoot(_ app: Application) throws {
        // Tests boot the whole application; none of them want a timer deleting files.
        guard app.environment != .testing else { return }

        let directory = app.binderService.personalBindersDirectory
        app.logger.notice("[BinderCache] Sweeping expired binders from \(directory.path) every \(BoxTokenKeepAlive.describe(Self.sweepInterval))")

        app.storage[TaskKey.self] = Task {
            do {
                try await Task.sleep(for: Self.initialDelay)
            } catch {
                return  // cancelled during the initial delay
            }
            while !Task.isCancelled {
                await Self.sweepOnce(app: app)
                do {
                    try await Task.sleep(for: Self.sweepInterval)
                } catch {
                    return  // cancelled while waiting
                }
            }
        }
    }

    func shutdown(_ app: Application) {
        app.storage[TaskKey.self]?.cancel()
    }

    /// Sweeps once and logs what went. Never throws: this runs unattended.
    static func sweepOnce(app: Application) async {
        do {
            let summary = try await sweep(
                directory: app.binderService.personalBindersDirectory,
                db: app.db, logger: app.logger)
            if summary.isEmpty {
                app.logger.debug("[BinderCache] Nothing has expired")
            } else {
                app.logger.notice("[BinderCache] Removed \(summary.rows) expired binder request(s) and \(summary.files) file(s), freeing \(summary.bytes) bytes")
            }
        } catch {
            app.logger.error("[BinderCache] Sweep failed: \(error)")
        }
    }

    // MARK: - The retention period

    /// Where the retention period in force came from, for the admin page.
    enum Source: String, Encodable, Sendable {
        /// Set from the admin page, and stored in `settings`.
        case admin
        /// `BINDER_RETENTION_DAYS`.
        case environment
        /// Neither: ``defaultRetentionDays``.
        case builtIn
    }

    struct Retention: Equatable, Sendable {
        let days: Int
        let source: Source

        /// When a binder built at `date` expires.
        func expiry(after date: Date) -> Date {
            date.addingTimeInterval(TimeInterval(days) * 24 * 60 * 60)
        }
    }

    /// A retention period as written by a person: a whole number of days, at least 1.
    static func parseDays(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces),
              let days = Int(raw), days >= 1 else {
            return nil
        }
        return days
    }

    /// The retention period in force: an admin's setting, else `BINDER_RETENTION_DAYS`,
    /// else ``defaultRetentionDays``. A value that is not a whole number of days, at least
    /// 1, is passed over as though it were unset.
    static func retention(
        on db: any Database,
        environment: (String) -> String? = Environment.get
    ) async throws -> Retention {
        if let days = parseDays(try await Setting.value(for: Setting.binderRetentionDays, on: db)) {
            return Retention(days: days, source: .admin)
        }
        if let days = parseDays(environment("BINDER_RETENTION_DAYS")) {
            return Retention(days: days, source: .environment)
        }
        return Retention(days: defaultRetentionDays, source: .builtIn)
    }

    // MARK: - Sweeping

    /// What one sweep removed.
    struct SweepSummary: Equatable, Sendable {
        var rows = 0
        var files = 0
        var bytes: Int64 = 0

        var isEmpty: Bool { rows == 0 && files == 0 }
    }

    /// Deletes every binder in `directory` whose time is up at `now`, and its row.
    static func sweep(
        directory: URL,
        db: any Database,
        now: Date = Date(),
        environment: (String) -> String? = Environment.get,
        logger: Logger
    ) async throws -> SweepSummary {
        let retention = try await retention(on: db, environment: environment)
        let fileManager = FileManager.default
        var summary = SweepSummary()

        // Rows first, so the files they named are known to be gone or kept before any
        // file is judged on its own.
        var kept = Set<String>()
        for request in try await BinderRequest.query(on: db).all() {
            let expiry = request.expiresAt
                ?? retention.expiry(after: request.createdAt ?? .distantPast)
            guard expiry <= now else {
                if let path = request.pdfPath {
                    kept.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
                }
                continue
            }
            if let path = request.pdfPath, fileManager.fileExists(atPath: path) {
                let size = fileSize(atPath: path)
                try fileManager.removeItem(atPath: path)
                summary.files += 1
                summary.bytes += size
            }
            try await request.delete(on: db)
            summary.rows += 1
            logger.info("[BinderCache] Expired binder \(request.id?.uuidString ?? "?") '\(request.definition.name)'")
        }

        // Then anything left in the directory that no row is keeping.
        for file in try files(in: directory) where !kept.contains(file.standardizedFileURL.path) {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard retention.expiry(after: values.contentModificationDate ?? .distantPast) <= now else {
                continue
            }
            try fileManager.removeItem(at: file)
            summary.files += 1
            summary.bytes += Int64(values.fileSize ?? 0)
            logger.info("[BinderCache] Removed orphaned file \(file.lastPathComponent)")
        }

        return summary
    }

    // MARK: - What is on disk

    /// The binder PDFs on disk, for the admin page.
    struct Usage: Equatable, Sendable {
        let count: Int
        let bytes: Int64
    }

    /// Counts the PDFs in `directory` and the space they take. Read from the disk rather
    /// than the database, because disk usage is the question being asked.
    static func usage(of directory: URL) throws -> Usage {
        let pdfs = try files(in: directory).filter { $0.pathExtension.lowercased() == "pdf" }
        let bytes = pdfs.reduce(Int64(0)) { $0 + fileSize(atPath: $1.path) }
        return Usage(count: pdfs.count, bytes: bytes)
    }

    /// The regular files directly inside `directory`; none when it does not exist yet.
    private static func files(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory,
                                 includingPropertiesForKeys: [.isRegularFileKey],
                                 options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private static func fileSize(atPath path: String) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
        return (size as? NSNumber)?.int64Value ?? 0
    }
}
