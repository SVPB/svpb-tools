import AsyncHTTPClient
import Fluent
import FluentSQLiteDriver
import Foundation
import NIOCore
import NIOHTTP1
import Vapor

// MARK: - DatabaseBackup

/// Copies the SQLite database to an off-site object store on a timer (#4).
///
/// The database is the one piece of state TNG cannot regenerate: the music workspace
/// re-clones, the PDFs re-render, Caddy's certificates re-issue, but the users, the
/// catalogue, the build history and the binder requests exist nowhere else. A block
/// volume protects them from losing the droplet. It does not protect them from a
/// corrupted file, a migration that damages rows, an `rm` on the wrong path, or the
/// wish to see what Monday looked like on Tuesday — and a copy somewhere else covers all
/// of those.
///
/// The copy is taken with `VACUUM INTO`, which reads the live database inside one
/// transaction and writes a consistent, compacted file. Copying the file itself while
/// the server has it open can produce a torn copy that will not open.
///
/// Each run puts one timestamped object into the bucket and never lists or deletes
/// anything: expiring old copies is the bucket's own lifecycle rule (README § Backups), so
/// a server that misbehaves can add backups but has no code path that removes them.
///
/// In-process for the same reason as `BoxTokenKeepAlive`: an external timer is one more
/// thing to forget when the droplet is rebuilt, and an in-process one can say in Slack
/// when it stops working.
struct DatabaseBackup: LifecycleHandler {

    /// Setting key recording whether the last backup worked, so a change of outcome can
    /// be announced without announcing the same state every night.
    static let healthKey = "backup.healthy"

    /// Setting key holding the object key of the last backup that was stored.
    static let lastObjectKey = "backup.last_object"

    /// Setting key holding when the last stored backup was taken, ISO 8601.
    static let lastSuccessKey = "backup.last_success"

    /// How long to wait after boot before the first backup. Long enough to stay out of
    /// the way of a server coming up; short enough that whoever deployed it sees the
    /// first one land, or hears in Slack that it did not.
    static let initialDelay: Duration = .seconds(60)

    /// Hours between backups, from `BACKUP_INTERVAL_HOURS`. Nightly by default.
    static func interval(from environment: @autoclosure () -> String?) -> Duration {
        BoxTokenKeepAlive.interval(from: environment())
    }

    // MARK: - Lifecycle

    private struct TaskKey: StorageKey { typealias Value = Task<Void, Never> }

    func didBoot(_ app: Application) throws {
        // Tests boot the whole application; none of them want a timer writing to a bucket.
        guard app.environment != .testing else { return }

        let configuration: Configuration
        switch Configuration.load(from: Environment.get) {
        case .unconfigured:
            app.logger.warning("[Backup] No BACKUP_* settings: the database is not being backed up")
            return
        case .incomplete(let missing):
            // Announced rather than only logged: someone tried to turn backups on and
            // would otherwise believe they had.
            app.logger.error("[Backup] Not backing up — missing \(missing.joined(separator: ", "))")
            app.storage[TaskKey.self] = Task {
                try? await Task.sleep(for: Self.initialDelay)
                guard !Task.isCancelled else { return }
                await Self.record(app: app, failure: "missing \(missing.joined(separator: ", "))")
            }
            return
        case .ready(let ready):
            configuration = ready
        }

        let interval = Self.interval(from: Environment.get("BACKUP_INTERVAL_HOURS"))
        app.logger.notice(
            "[Backup] Backing up to \(configuration.bucket) every \(BoxTokenKeepAlive.describe(interval))")

        app.storage[TaskKey.self] = Task {
            do {
                try await Task.sleep(for: Self.initialDelay)
            } catch {
                return  // cancelled during the initial delay
            }
            while !Task.isCancelled {
                await Self.runOnce(app: app, configuration: configuration)
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return  // cancelled while waiting
                }
            }
        }
    }

    func shutdown(_ app: Application) {
        app.storage[TaskKey.self]?.cancel()
    }

    // MARK: - One pass

    /// Takes one backup, stores it, and announces a change of outcome.
    ///
    /// Never throws: this runs unattended, and a failure is something to report rather
    /// than something to crash a background task over.
    static func runOnce(app: Application, configuration: Configuration, now: Date = Date()) async {
        let key = configuration.objectKey(at: now)
        var failure: String?
        do {
            let snapshot = try await Self.snapshot(of: app.db)
            try await Self.upload(snapshot, key: key, configuration: configuration,
                                  httpClient: app.sharedHTTPClient, now: now)
            app.logger.info("[Backup] Stored \(key) (\(snapshot.count) bytes)")
        } catch {
            failure = "\(error)"
            app.logger.error("[Backup] Backup failed: \(error)")
        }

        if failure == nil {
            do {
                try await Setting.set(lastObjectKey, to: key, on: app.db)
                try await Setting.set(lastSuccessKey, to: ISO8601DateFormatter().string(from: now),
                                      on: app.db)
            } catch {
                app.logger.warning("[Backup] Could not record the backup: \(error)")
            }
        }
        await record(app: app, failure: failure)
    }

    /// Announces the outcome if it differs from the last one, then stores it.
    private static func record(app: Application, failure: String?) async {
        let previous: Bool?
        do {
            previous = try await Setting.value(for: healthKey, on: app.db).map { $0 == "true" }
        } catch {
            app.logger.warning("[Backup] Could not read the last backup outcome: \(error)")
            previous = nil
        }

        if let message = announcement(previous: previous, failure: failure) {
            do {
                try await app.slackService.postPlainMessage(message)
            } catch {
                app.logger.warning("[Backup] Could not announce the backup outcome to Slack: \(error)")
            }
        }

        do {
            try await Setting.set(healthKey, to: failure == nil ? "true" : "false", on: app.db)
        } catch {
            app.logger.warning("[Backup] Could not record the backup outcome: \(error)")
        }
    }

    // MARK: - Taking the copy

    /// A consistent copy of the open database, as the bytes of an SQLite file.
    ///
    /// `VACUUM INTO` refuses to overwrite, so the copy is written to a fresh name in the
    /// temporary directory and removed once read.
    static func snapshot(of db: any Database) async throws -> Data {
        guard let sql = db as? any SQLDatabase else {
            throw BackupError.notSQL
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tng-backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }

        try await sql.raw("VACUUM INTO \(bind: file.path)").run()
        return try Data(contentsOf: file)
    }

    // MARK: - Storing it

    /// PUTs `body` into the bucket under `key`.
    static func upload(
        _ body: Data,
        key: String,
        configuration: Configuration,
        httpClient: HTTPClient,
        now: Date
    ) async throws {
        let path = "/\(configuration.bucket)/\(key)"
        let host = configuration.hostHeader
        let payloadHash = S3Signer.payloadHash(body)
        let contentType = "application/vnd.sqlite3"

        var request = HTTPClientRequest(
            url: configuration.endpoint.absoluteString + S3Signer.encodePath(path))
        request.method = .PUT
        request.headers.add(name: "Content-Type", value: contentType)
        for (name, value) in configuration.signer.signedHeaders(
            method: "PUT", path: path, host: host,
            headers: ["Content-Type": contentType],
            payloadHash: payloadHash, date: now
        ) {
            request.headers.add(name: name, value: value)
        }
        request.body = .bytes(ByteBuffer(bytes: body))

        let response = try await httpClient.execute(request, timeout: .minutes(5))
        let reply = try await response.body.collect(upTo: 64 * 1024)
        guard response.status == .ok else {
            throw BackupError.rejected(status: response.status.code,
                                       body: String(buffer: reply))
        }
    }

    // MARK: - What to say, and when

    /// The Slack message for this backup, or `nil` when there is nothing new to say.
    ///
    /// The same rule as the Box renewal: only a *change* is news. A nightly "backed up"
    /// is how a channel gets muted, and a muted channel is how a month of failed backups
    /// goes unnoticed until the night one is needed.
    static func announcement(previous: Bool?, failure: String?) -> String? {
        switch (previous, failure) {
        case (_, .some(let error)) where previous != false:
            return """
                ⚠️ *The nightly database backup is failing.* Until it is fixed, a lost or \
                damaged database can only be restored from the last backup that worked.
                ```
                \(error)
                ```
                Check the Connections page on the admin dashboard.
                """
        case (.some(false), .none):
            return "✅ *The nightly database backup is working again.*"
        default:
            return nil
        }
    }
}

// MARK: - Configuration

extension DatabaseBackup {

    /// Where backups go, from the `BACKUP_*` environment variables.
    struct Configuration: Sendable, Equatable {
        /// The store's endpoint, scheme and host only: `https://sfo3.digitaloceanspaces.com`.
        let endpoint: URL
        let bucket: String
        let region: String
        /// Prepended to every object key, so the bucket can hold other things too.
        let prefix: String
        let accessKey: String
        let secretKey: String

        /// The outcome of reading the environment.
        enum Loaded: Equatable {
            /// Nothing set: backups are off, which is a choice.
            case unconfigured
            /// Some set and some not: backups are off, which is a mistake.
            case incomplete(missing: [String])
            case ready(Configuration)
        }

        static let required = ["BACKUP_ENDPOINT", "BACKUP_BUCKET",
                               "BACKUP_ACCESS_KEY", "BACKUP_SECRET_KEY"]

        static func load(from environment: (String) -> String?) -> Loaded {
            func value(_ name: String) -> String? {
                environment(name)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            }

            let missing = required.filter { value($0) == nil }
            if missing.count == required.count { return .unconfigured }

            var endpoint = value("BACKUP_ENDPOINT").flatMap(URL.init(string:))
            if endpoint?.scheme == nil || endpoint?.host == nil { endpoint = nil }
            let invalid = value("BACKUP_ENDPOINT") != nil && endpoint == nil
                ? ["BACKUP_ENDPOINT (not a URL)"] : []
            guard missing.isEmpty, invalid.isEmpty, let endpoint else {
                return .incomplete(missing: missing + invalid)
            }

            var prefix = value("BACKUP_PREFIX") ?? "tng/"
            if !prefix.hasSuffix("/") { prefix += "/" }
            if prefix.hasPrefix("/") { prefix.removeFirst() }

            return .ready(Configuration(
                endpoint: endpoint,
                bucket: value("BACKUP_BUCKET")!,
                region: value("BACKUP_REGION") ?? defaultRegion(for: endpoint),
                prefix: prefix,
                accessKey: value("BACKUP_ACCESS_KEY")!,
                secretKey: value("BACKUP_SECRET_KEY")!))
        }

        /// A DigitalOcean endpoint names its region as its first label —
        /// `sfo3.digitaloceanspaces.com` — and anything else gets the conventional
        /// default, which Spaces, MinIO and most other S3 lookalikes also accept.
        static func defaultRegion(for endpoint: URL) -> String {
            guard let host = endpoint.host, host.hasSuffix(".digitaloceanspaces.com") else {
                return "us-east-1"
            }
            return String(host.prefix { $0 != "." })
        }

        /// `tng/tng-20261008T031500Z.sqlite`. The timestamp is UTC and sorts as text, so
        /// the newest backup is the last key in a listing.
        func objectKey(at date: Date) -> String {
            "\(prefix)tng-\(S3Signer.timestamp(date)).sqlite"
        }

        /// The `Host` header the request will carry, port included when it is not the
        /// scheme's default — it is signed, so it has to match exactly.
        var hostHeader: String {
            let host = endpoint.host ?? ""
            guard let port = endpoint.port else { return host }
            let isDefault = (endpoint.scheme == "https" && port == 443)
                || (endpoint.scheme == "http" && port == 80)
            return isDefault ? host : "\(host):\(port)"
        }

        var signer: S3Signer {
            S3Signer(accessKey: accessKey, secretKey: secretKey, region: region)
        }
    }

    /// The state of backups for the connections page, from what the last run recorded.
    struct Status: Sendable {
        let loaded: Configuration.Loaded
        let healthy: Bool?
        let lastObject: String?
        let lastSuccess: Date?
    }

    static func status(on db: any Database) async -> Status {
        let loaded = Configuration.load(from: Environment.get)
        let healthy = (try? await Setting.value(for: healthKey, on: db)).map { $0 == "true" }
        let lastObject = try? await Setting.value(for: lastObjectKey, on: db)
        let lastSuccess = (try? await Setting.value(for: lastSuccessKey, on: db))
            .flatMap(ISO8601DateFormatter().date(from:))
        return Status(loaded: loaded, healthy: healthy,
                      lastObject: lastObject, lastSuccess: lastSuccess)
    }
}

// MARK: - Errors

enum BackupError: Error, CustomStringConvertible, Equatable {
    /// The database is not one `VACUUM INTO` can be run against.
    case notSQL
    /// The store answered, and said no.
    case rejected(status: UInt, body: String)

    var description: String {
        switch self {
        case .notSQL:
            return "The database does not accept SQL, so it cannot be copied with VACUUM INTO"
        case .rejected(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "The store refused the upload with HTTP \(status)"
                + (detail.isEmpty ? "" : ": \(detail.prefix(500))")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
