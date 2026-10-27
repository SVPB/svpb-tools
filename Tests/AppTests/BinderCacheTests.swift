import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// Personal binders are kept for the retention period and then deleted — the PDF and its
/// row, failed requests, and files nothing names — and nothing younger is touched (#83).
final class BinderCacheTests: XCTestCase {

    var app: Application!
    var directory: URL!

    /// No `BINDER_RETENTION_DAYS`, whatever the machine running the tests has set.
    let noEnvironment: (String) -> String? = { _ in nil }

    static let day: TimeInterval = 24 * 60 * 60

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binder-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The retention period

    func testRetentionIsTheBuiltInDefaultWhenNothingIsSet() async throws {
        let retention = try await BinderCache.retention(on: app.db, environment: noEnvironment)
        XCTAssertEqual(retention, .init(days: BinderCache.defaultRetentionDays, source: .builtIn))
    }

    func testEnvironmentOverridesTheDefault() async throws {
        let retention = try await BinderCache.retention(
            on: app.db, environment: { $0 == "BINDER_RETENTION_DAYS" ? " 30 " : nil })
        XCTAssertEqual(retention, .init(days: 30, source: .environment))
    }

    func testAdminSettingOverridesTheEnvironment() async throws {
        try await Setting.set(Setting.binderRetentionDays, to: "3", on: app.db)
        let retention = try await BinderCache.retention(
            on: app.db, environment: { $0 == "BINDER_RETENTION_DAYS" ? "30" : nil })
        XCTAssertEqual(retention, .init(days: 3, source: .admin))
    }

    /// A value that is not a whole number of days, at least 1, is passed over rather than
    /// deleting every binder the moment it is built.
    func testUnusableValuesArePassedOver() async throws {
        for raw in ["0", "-2", "1.5", "a week", ""] {
            XCTAssertNil(BinderCache.parseDays(raw), raw)
        }
        try await Setting.set(Setting.binderRetentionDays, to: "0", on: app.db)
        let retention = try await BinderCache.retention(
            on: app.db, environment: { $0 == "BINDER_RETENTION_DAYS" ? "never" : nil })
        XCTAssertEqual(retention, .init(days: BinderCache.defaultRetentionDays, source: .builtIn))
    }

    // MARK: - Sweeping

    func testExpiredBinderLosesItsFileAndRow() async throws {
        let now = Date()
        let expired = try await seedBinder(bytes: 100, expiresAt: now.addingTimeInterval(-60))
        let current = try await seedBinder(bytes: 50, expiresAt: now.addingTimeInterval(Self.day))

        let summary = try await sweep(at: now)

        XCTAssertEqual(summary, .init(rows: 1, files: 1, bytes: 100))
        let gone = try await BinderRequest.find(expired.id, on: app.db)
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(expired.pdfPath)))
        let kept = try await BinderRequest.find(current.id, on: app.db)
        XCTAssertNotNil(kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(current.pdfPath)))
    }

    /// The expiry stamped on a binder holds whatever the period is now: shortening it does
    /// not cut short what a binder was promised.
    func testStampedExpiryHoldsWhenThePeriodChanges() async throws {
        let now = Date()
        let binder = try await seedBinder(bytes: 10, expiresAt: now.addingTimeInterval(10 * Self.day))
        try await Setting.set(Setting.binderRetentionDays, to: "1", on: app.db)

        let summary = try await sweep(at: now.addingTimeInterval(2 * Self.day))

        XCTAssertTrue(summary.isEmpty)
        let kept = try await BinderRequest.find(binder.id, on: app.db)
        XCTAssertNotNil(kept)
    }

    /// A request that failed, or that predates retention, has no expiry of its own; it goes
    /// when the current period has passed since it was made.
    func testRowWithoutExpiryGoesAfterThePeriodFromCreation() async throws {
        let failed = BinderRequest(definition: spec())
        try await failed.save(on: app.db)
        let legacy = try await seedBinder(bytes: 20, expiresAt: nil)
        let created = try XCTUnwrap(failed.createdAt)

        let early = try await sweep(at: created.addingTimeInterval(13 * Self.day))
        XCTAssertTrue(early.isEmpty, "Neither is older than the 14-day default")

        let summary = try await sweep(at: created.addingTimeInterval(15 * Self.day))
        XCTAssertEqual(summary, .init(rows: 2, files: 1, bytes: 20))
        let remaining = try await BinderRequest.query(on: app.db).count()
        XCTAssertEqual(remaining, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(legacy.pdfPath)))
    }

    /// A file no row names is judged by its age, so binders written before their rows were
    /// lost still go — and one being written right now does not.
    func testOrphanedFilesGoByAge() async throws {
        let now = Date()
        let old = try writeFile("\(UUID().uuidString).pdf", bytes: 30,
                                modified: now.addingTimeInterval(-15 * Self.day))
        let fresh = try writeFile("\(UUID().uuidString).pdf", bytes: 40, modified: now)

        let summary = try await sweep(at: now)

        XCTAssertEqual(summary, .init(rows: 0, files: 1, bytes: 30))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// A kept binder's file is never treated as an orphan, however old the file is.
    func testFileOfAKeptBinderIsNotAnOrphan() async throws {
        let now = Date()
        let binder = try await seedBinder(bytes: 10, expiresAt: now.addingTimeInterval(Self.day))
        let path = try XCTUnwrap(binder.pdfPath)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-100 * Self.day)], ofItemAtPath: path)

        let summary = try await sweep(at: now)

        XCTAssertTrue(summary.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testSweepOfAMissingDirectoryIsEmpty() async throws {
        try FileManager.default.removeItem(at: directory)
        let summary = try await sweep(at: Date())
        XCTAssertTrue(summary.isEmpty)
    }

    // MARK: - What is on disk

    func testUsageCountsPDFsAndTheirSize() throws {
        _ = try writeFile("a.pdf", bytes: 1000, modified: Date())
        _ = try writeFile("b.pdf", bytes: 24, modified: Date())
        _ = try writeFile("notes.txt", bytes: 500, modified: Date())

        XCTAssertEqual(try BinderCache.usage(of: directory), .init(count: 2, bytes: 1024))
        XCTAssertEqual(
            try BinderCache.usage(of: directory.appendingPathComponent("nowhere")),
            .init(count: 0, bytes: 0))
    }

    // MARK: - What the builder is told

    func testStatusCarriesTheExpiryOnceReady() async throws {
        let expiresAt = Date(timeIntervalSince1970: 1_800_000_000)
        let ready = try await seedBinder(bytes: 1, expiresAt: expiresAt)
        let readyDTO = try BinderStatusDTO(from: ready)
        XCTAssertEqual(readyDTO.expiresAt, "2027-01-15T08:00:00Z")

        let pending = BinderRequest(definition: spec())
        try await pending.save(on: app.db)
        XCTAssertNil(try BinderStatusDTO(from: pending).expiresAt)
    }

    func testMissingBinderSaysItMayHaveExpired() async throws {
        try await app.test(.GET, "/binders/\(UUID().uuidString)/download") { response async in
            XCTAssertEqual(response.status, .notFound)
            XCTAssertTrue(response.body.string.contains("build it again"), response.body.string)
        }
    }

    // MARK: - The admin page

    func testAdminRoutesAreAdminOnly() async throws {
        try await app.test(.GET, "/admin/binders") { response async in
            XCTAssertEqual(response.status, .seeOther)
            XCTAssertEqual(response.headers.first(name: .location), "/admin/login")
        }
        try await app.test(.PUT, "/admin/binders/retention", beforeRequest: { req in
            try req.content.encode(["days": 1])
        }) { response async in
            XCTAssertEqual(response.status, .seeOther)
            XCTAssertEqual(response.headers.first(name: .location), "/admin/login")
        }
        let stored = try await Setting.value(for: Setting.binderRetentionDays, on: app.db)
        XCTAssertNil(stored)
    }

    /// The admin routes are behind a session, so rendering the template directly is what
    /// catches a broken one before a deployment does.
    func testPageRendersEachSource() async throws {
        for source in [BinderCache.Source.admin, .environment, .builtIn] {
            let view = try await app.view.render("admin/binders", BinderCacheController.Context(
                appVersion: AppVersion.current, isAdmin: true, currentUser: "tester",
                retentionDays: 9, retentionSource: source,
                binderCount: 17, binderSize: "3.2 MB", directory: "/music/binders"))
            let html = String(buffer: view.data)

            XCTAssertTrue(html.contains(#"value="9""#), html)
            XCTAssertTrue(html.contains(">17<"))
            XCTAssertTrue(html.contains("3.2 MB"))
            XCTAssertFalse(html.contains("#if("), "Unrendered Leaf tags left in the output")
            switch source {
            case .admin: XCTAssertTrue(html.contains("Set on this page"))
            case .environment: XCTAssertTrue(html.contains("From <code>BINDER_RETENTION_DAYS</code>"))
            case .builtIn: XCTAssertTrue(html.contains("The built-in default"))
            }
        }
    }

    // MARK: - Helpers

    private func sweep(at now: Date) async throws -> BinderCache.SweepSummary {
        try await BinderCache.sweep(directory: directory, db: app.db, now: now,
                                    environment: noEnvironment, logger: app.logger)
    }

    private func spec() -> BinderSpec {
        BinderSpec(name: "Mine", branch: "2026", sections: [])
    }

    /// A built binder: its PDF in the directory, and its row pointing at it.
    private func seedBinder(bytes: Int, expiresAt: Date?) async throws -> BinderRequest {
        let id = UUID()
        let file = try writeFile("\(id).pdf", bytes: bytes, modified: Date())
        let request = BinderRequest(id: id, definition: spec(), pdfPath: file.path)
        request.expiresAt = expiresAt
        try await request.create(on: app.db)
        return request
    }

    private func writeFile(_ name: String, bytes: Int, modified: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }
}
