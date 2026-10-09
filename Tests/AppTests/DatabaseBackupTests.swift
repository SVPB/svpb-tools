import Fluent
import FluentSQLiteDriver
import Foundation
import NIOConcurrencyHelpers
import XCTVapor
import XCTest
@testable import App

/// The nightly off-site database backup (#4).
///
/// The database is the only state TNG cannot regenerate, so what is tested here is the
/// chain a restore depends on: that the copy is a database that opens and holds the
/// rows, that the upload is signed the way an S3-compatible store will accept, and that
/// a failure is announced once rather than every night or never.
final class DatabaseBackupTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    // MARK: - Signing

    /// AWS's own worked example for Signature Version 4 against S3 ("GET Object"), so
    /// the signer is checked against something other than itself.
    func testSignsAWSPublishedGetExample() throws {
        let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE",
                              secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                              region: "us-east-1")
        let headers = signer.signedHeaders(
            method: "GET", path: "/test.txt", host: "examplebucket.s3.amazonaws.com",
            headers: ["Range": "bytes=0-9"],
            payloadHash: S3Signer.payloadHash(Data()),
            date: Date(timeIntervalSince1970: 1_369_353_600))  // 2013-05-24T00:00:00Z

        let authorization = try XCTUnwrap(headers.first { $0.0 == "Authorization" }?.1)
        XCTAssertEqual(authorization, """
            AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, \
            SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, \
            Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41
            """)
        XCTAssertEqual(headers.first { $0.0 == "x-amz-date" }?.1, "20130524T000000Z")
    }

    /// The same document's "PUT Object" example, which also exercises a body, a path that
    /// needs encoding (`$`), and headers passed in mixed case.
    func testSignsAWSPublishedPutExample() throws {
        let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE",
                              secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                              region: "us-east-1")
        let body = Data("Welcome to Amazon S3.".utf8)
        XCTAssertEqual(S3Signer.payloadHash(body),
                       "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")

        let headers = signer.signedHeaders(
            method: "PUT", path: "/test$file.text", host: "examplebucket.s3.amazonaws.com",
            headers: ["Date": "Fri, 24 May 2013 00:00:00 GMT",
                      "x-amz-storage-class": "REDUCED_REDUNDANCY"],
            payloadHash: S3Signer.payloadHash(body),
            date: Date(timeIntervalSince1970: 1_369_353_600))

        let authorization = try XCTUnwrap(headers.first { $0.0 == "Authorization" }?.1)
        XCTAssertTrue(authorization.hasSuffix(
            "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"),
            authorization)
    }

    func testPathEncodingKeepsSlashesAndEncodesTheRest() {
        XCTAssertEqual(S3Signer.encodePath("/bucket/tng/tng-20261008T031500Z.sqlite"),
                       "/bucket/tng/tng-20261008T031500Z.sqlite")
        XCTAssertEqual(S3Signer.encodePath("/b/a b+c$é"), "/b/a%20b%2Bc%24%C3%A9")
    }

    // MARK: - Configuration

    private func load(_ values: [String: String]) -> DatabaseBackup.Configuration.Loaded {
        DatabaseBackup.Configuration.load(from: { values[$0] })
    }

    private static let complete = [
        "BACKUP_ENDPOINT": "https://sfo3.digitaloceanspaces.com",
        "BACKUP_BUCKET": "svpb-backups",
        "BACKUP_ACCESS_KEY": "DO00EXAMPLE",
        "BACKUP_SECRET_KEY": "secret",
    ]

    /// Nothing set is a choice — a development machine — and is not an error.
    func testNothingSetIsUnconfigured() {
        XCTAssertEqual(load([:]), .unconfigured)
        XCTAssertEqual(load(["BACKUP_BUCKET": "  "]), .unconfigured,
                       "A blank value is no value")
    }

    /// Half a configuration is a mistake, and has to say which half is missing — an
    /// operator who set three of four variables believes backups are on.
    func testPartialConfigurationNamesWhatIsMissing() {
        var values = Self.complete
        values["BACKUP_SECRET_KEY"] = nil
        XCTAssertEqual(load(values), .invalid(problems: ["BACKUP_SECRET_KEY is not set"]))

        values = Self.complete
        values["BACKUP_ENDPOINT"] = "sfo3.digitaloceanspaces.com"
        guard case .invalid(let problems) = load(values) else {
            return XCTFail("An endpoint without a scheme cannot be requested")
        }
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].hasPrefix("BACKUP_ENDPOINT"), problems[0])
    }

    // MARK: - The Origin Endpoint

    /// The URL DigitalOcean shows on the bucket's page is the one an operator will paste,
    /// and it is enough on its own: the bucket and the region are both in it.
    func testOriginEndpointNamesTheBucketAndRegion() throws {
        let loaded = load([
            "BACKUP_ENDPOINT": "https://tng-backups.sfo3.digitaloceanspaces.com",
            "BACKUP_ACCESS_KEY": "DO00EXAMPLE",
            "BACKUP_SECRET_KEY": "secret",
        ])
        guard case .ready(let configuration) = loaded else {
            return XCTFail("expected a usable configuration, got \(loaded)")
        }
        XCTAssertEqual(configuration.bucket, "tng-backups")
        XCTAssertEqual(configuration.region, "sfo3")
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://sfo3.digitaloceanspaces.com",
                       "Requests go to the regional endpoint, with the bucket in the path")
        XCTAssertEqual(configuration.hostHeader, "sfo3.digitaloceanspaces.com")
    }

    /// A trailing slash, or upper case, is still the same URL.
    func testOriginEndpointToleratesWhatAPasteBringsWithIt() throws {
        let parsed = try XCTUnwrap(DatabaseBackup.Configuration.parseEndpoint(
            "https://TNG-Backups.SFO3.digitaloceanspaces.com/"))
        XCTAssertEqual(parsed.bucket, "tng-backups")
        XCTAssertEqual(parsed.endpoint.absoluteString, "https://sfo3.digitaloceanspaces.com")
    }

    /// Naming the bucket twice is fine when both say the same thing.
    func testABucketNamedTwiceTheSameWayIsAccepted() {
        var values = Self.complete
        values["BACKUP_ENDPOINT"] = "https://svpb-backups.sfo3.digitaloceanspaces.com"
        guard case .ready(let configuration) = load(values) else {
            return XCTFail("expected a usable configuration")
        }
        XCTAssertEqual(configuration.bucket, "svpb-backups")
    }

    /// …and refused when they do not, rather than backing up to whichever one won.
    func testABucketNamedTwoWaysIsRefused() {
        var values = Self.complete
        values["BACKUP_ENDPOINT"] = "https://tng-backups.sfo3.digitaloceanspaces.com"
        guard case .invalid(let problems) = load(values) else {
            return XCTFail("two different buckets must not resolve to one")
        }
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("svpb-backups") && problems[0].contains("tng-backups"),
                      "Both names, so the operator can see which to fix: \(problems[0])")
    }

    /// The regional endpoint names no bucket, so one still has to be given.
    func testARegionalEndpointStillNeedsABucket() {
        var values = Self.complete
        values["BACKUP_BUCKET"] = nil
        guard case .invalid(let problems) = load(values) else {
            return XCTFail("expected the missing bucket to be reported")
        }
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].hasPrefix("BACKUP_BUCKET"), problems[0])
    }

    /// Only DigitalOcean's hosts are taken apart. An AWS virtual-hosted URL puts the
    /// bucket first too, but in a different shape, and a local store has no bucket in its
    /// name at all; both are used as they stand.
    func testOtherStoresAreNotTakenApart() throws {
        let local = try XCTUnwrap(DatabaseBackup.Configuration.parseEndpoint("http://127.0.0.1:9000"))
        XCTAssertNil(local.bucket)
        XCTAssertEqual(local.endpoint.absoluteString, "http://127.0.0.1:9000")

        let aws = try XCTUnwrap(DatabaseBackup.Configuration.parseEndpoint(
            "https://s3.us-west-2.amazonaws.com"))
        XCTAssertNil(aws.bucket)
    }

    /// The CDN endpoint serves reads; an upload sent there would not land in the bucket.
    func testTheCDNEndpointIsRefused() {
        XCTAssertNil(DatabaseBackup.Configuration.parseEndpoint(
            "https://tng-backups.sfo3.cdn.digitaloceanspaces.com"))
        XCTAssertNil(DatabaseBackup.Configuration.parseEndpoint("ftp://sfo3.digitaloceanspaces.com"))
    }

    func testCompleteConfigurationDerivesTheSpacesRegion() throws {
        guard case .ready(let configuration) = load(Self.complete) else {
            return XCTFail("expected a usable configuration")
        }
        XCTAssertEqual(configuration.region, "sfo3")
        XCTAssertEqual(configuration.prefix, "tng/")
        XCTAssertEqual(configuration.hostHeader, "sfo3.digitaloceanspaces.com")
    }

    func testRegionAndPrefixCanBeSet() throws {
        var values = Self.complete
        values["BACKUP_ENDPOINT"] = "http://127.0.0.1:9000"
        values["BACKUP_PREFIX"] = "/nightly"
        guard case .ready(let configuration) = load(values) else {
            return XCTFail("expected a usable configuration")
        }
        XCTAssertEqual(configuration.region, "us-east-1",
                       "A store that is not Spaces gets the conventional default")
        XCTAssertEqual(configuration.prefix, "nightly/")
        XCTAssertEqual(configuration.hostHeader, "127.0.0.1:9000",
                       "The port is part of the signed Host header")

        values["BACKUP_REGION"] = "nyc3"
        guard case .ready(let explicit) = load(values) else {
            return XCTFail("expected a usable configuration")
        }
        XCTAssertEqual(explicit.region, "nyc3")
    }

    /// Keys sort by time as text, so "the newest backup" is the last key in a listing —
    /// which is what the restore script relies on.
    func testObjectKeysSortByTime() throws {
        guard case .ready(let configuration) = load(Self.complete) else {
            return XCTFail("expected a usable configuration")
        }
        let earlier = configuration.objectKey(at: Date(timeIntervalSince1970: 1_791_000_000))
        let later = configuration.objectKey(at: Date(timeIntervalSince1970: 1_791_100_000))
        XCTAssertEqual(earlier, "tng/tng-20261003T040000Z.sqlite")
        XCTAssertLessThan(earlier, later)
    }

    // MARK: - The copy

    /// The point of a backup is that it restores. The copy is opened as a database in its
    /// own right and the row written before it was taken is read back out of it.
    func testSnapshotIsADatabaseHoldingTheRows() async throws {
        try await Setting.set("test.marker", to: "before the backup", on: app.db)

        let bytes = try await DatabaseBackup.snapshot(of: app.db)
        XCTAssertEqual(bytes.prefix(16), Data("SQLite format 3\0".utf8))

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("restored-\(UUID().uuidString).sqlite")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let restored = DatabaseID(string: "restored")
        app.databases.use(.sqlite(.file(file.path)), as: restored)
        let value = try await Setting.value(for: "test.marker", on: app.db(restored))
        XCTAssertEqual(value, "before the backup")
    }

    // MARK: - The upload

    /// A stand-in for the object store: records each PUT and answers with `status`.
    private final class FakeStore: Sendable {
        struct Put: Sendable {
            let path: String
            let headers: HTTPHeaders
            let body: Data
        }
        let app: Application
        let puts = NIOLockedValueBox<[Put]>([])
        let status = NIOLockedValueBox<HTTPStatus>(.ok)

        init() async throws {
            app = try await Application.make(.testing)
            app.on(.PUT, "**", body: .collect(maxSize: "10mb")) { [puts, status] req in
                let body = req.body.data.map { Data(buffer: $0) } ?? Data()
                puts.withLockedValue {
                    $0.append(Put(path: req.url.path, headers: req.headers, body: body))
                }
                return Response(status: status.withLockedValue { $0 },
                                body: .init(string: "<Error><Code>AccessDenied</Code></Error>"))
            }
            try await app.asyncBoot()
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        }

        var endpoint: String {
            "http://127.0.0.1:\(app.http.server.shared.localAddress?.port ?? 0)"
        }

        func stop() async throws {
            await app.server.shutdown()
            try await app.asyncShutdown()
        }
    }

    private func configuration(at endpoint: String) throws -> DatabaseBackup.Configuration {
        var values = Self.complete
        values["BACKUP_ENDPOINT"] = endpoint
        guard case .ready(let configuration) = load(values) else {
            throw XCTSkip("fake store endpoint did not load")
        }
        return configuration
    }

    func testABackupIsPutIntoTheBucketAndRecorded() async throws {
        let store = try await FakeStore()
        do {
            let configuration = try configuration(at: store.endpoint)
            let now = Date(timeIntervalSince1970: 1_791_000_000)

            await DatabaseBackup.runOnce(app: app, configuration: configuration, now: now)

            let puts = store.puts.withLockedValue { $0 }
            XCTAssertEqual(puts.count, 1)
            let put = try XCTUnwrap(puts.first)
            XCTAssertEqual(put.path, "/svpb-backups/tng/tng-20261003T040000Z.sqlite")
            XCTAssertEqual(put.body.prefix(16), Data("SQLite format 3\0".utf8))
            XCTAssertEqual(put.headers.first(name: "x-amz-content-sha256"),
                           S3Signer.payloadHash(put.body),
                           "The signed hash is of the bytes that were actually sent")
            let authorization = try XCTUnwrap(put.headers.first(name: "Authorization"))
            XCTAssertTrue(authorization.contains("Credential=DO00EXAMPLE/20261003/us-east-1/s3/"),
                          authorization)

            let status = await DatabaseBackup.status(on: app.db)
            XCTAssertEqual(status.healthy, true)
            XCTAssertEqual(status.lastObject, "tng/tng-20261003T040000Z.sqlite")
            XCTAssertEqual(status.lastSuccess, now)
        } catch {
            try await store.stop()
            throw error
        }
        try await store.stop()
    }

    /// A refused upload is a failed backup, with the store's reason attached, and it does
    /// not overwrite the record of the last one that worked.
    func testARefusedUploadIsAFailureThatKeepsTheLastGoodBackup() async throws {
        let store = try await FakeStore()
        do {
            let configuration = try configuration(at: store.endpoint)
            let night1 = Date(timeIntervalSince1970: 1_791_000_000)
            await DatabaseBackup.runOnce(app: app, configuration: configuration, now: night1)

            store.status.withLockedValue { $0 = .forbidden }
            let snapshot = try await DatabaseBackup.snapshot(of: app.db)
            do {
                try await DatabaseBackup.upload(snapshot, key: "tng/x.sqlite",
                                                configuration: configuration,
                                                httpClient: app.sharedHTTPClient, now: Date())
                XCTFail("a 403 must not count as stored")
            } catch let error as BackupError {
                guard case .rejected(let code, let body) = error else {
                    return XCTFail("unexpected \(error)")
                }
                XCTAssertEqual(code, 403)
                XCTAssertTrue(body.contains("AccessDenied"), "The store's reason travels with it")
            }

            await DatabaseBackup.runOnce(app: app, configuration: configuration,
                                         now: night1.addingTimeInterval(86400))
            let status = await DatabaseBackup.status(on: app.db)
            XCTAssertEqual(status.healthy, false)
            XCTAssertEqual(status.lastSuccess, night1,
                           "The last backup that worked is still the one to restore from")
        } catch {
            try await store.stop()
            throw error
        }
        try await store.stop()
    }

    // MARK: - What gets announced

    func testOnlyAChangeOfOutcomeIsAnnounced() {
        XCTAssertNil(DatabaseBackup.announcement(previous: nil, failure: nil),
                     "A first backup that works is not news")
        XCTAssertNil(DatabaseBackup.announcement(previous: true, failure: nil))
        XCTAssertNil(DatabaseBackup.announcement(previous: false, failure: "still broken"),
                     "A fortnight of the same failure is one message, not fourteen")

        let failing = DatabaseBackup.announcement(previous: true, failure: "HTTP 403")
        XCTAssertTrue(failing?.contains("backup is failing") ?? false, failing ?? "nil")
        XCTAssertTrue(failing?.contains("HTTP 403") ?? false, "The error travels with the alarm")
        XCTAssertNotNil(DatabaseBackup.announcement(previous: nil, failure: "BACKUP_BUCKET is not set"),
                        "A first run that fails is news")
        XCTAssertEqual(DatabaseBackup.announcement(previous: false, failure: nil),
                       "✅ *The nightly database backup is working again.*")
    }

    // MARK: - The connections page

    func testConnectionsPageReportsUnconfiguredBackups() async throws {
        let connections = await ConnectionsReport.gather(on: app)
        let backup = try XCTUnwrap(connections.first { $0.id == "backup" })
        XCTAssertEqual(backup.state, .unconfigured)
        XCTAssertNotNil(backup.remedy)
    }
}
