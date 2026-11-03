import Foundation
import Logging
import XCTVapor
import XCTest
@testable import App

/// `configure` logs which Vapor environment the server runs as, and at what log level,
/// so the answer is in the first lines of `docker compose logs` (#95).
final class BootSummaryTests: XCTestCase {

    func testTheLineNamesTheEnvironmentAndLogLevel() {
        XCTAssertEqual(bootSummary(environment: .production, logLevel: .info),
                       "Environment: production, log level: info")
        XCTAssertEqual(bootSummary(environment: .development, logLevel: .notice),
                       "Environment: development, log level: notice")
    }

    func testConfigureLogsTheLineAtNotice() async throws {
        let captured = CapturedLogs()
        let app = try await Application.make(.testing)
        app.logger = Logger(label: "test") { _ in CapturingLogHandler(captured, level: .info) }
        do {
            try await configure(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()

        let boot = captured.entries.filter { $0.message.hasPrefix("Environment: ") }
        XCTAssertEqual(boot.count, 1)
        XCTAssertEqual(boot.first?.message, "Environment: testing, log level: info")
        XCTAssertEqual(boot.first?.level, .notice)
    }
}

/// Log entries a test reads back.
final class CapturedLogs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(level: Logger.Level, message: String)] = []

    var entries: [(level: Logger.Level, message: String)] { lock.withLock { stored } }

    func append(_ level: Logger.Level, _ message: String) {
        lock.withLock { stored.append((level, message)) }
    }
}

/// A log handler that records into ``CapturedLogs``.
struct CapturingLogHandler: LogHandler {
    let captured: CapturedLogs
    var logLevel: Logger.Level
    var metadata: Logger.Metadata = [:]

    init(_ captured: CapturedLogs, level: Logger.Level) {
        self.captured = captured
        self.logLevel = level
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        captured.append(event.level, "\(event.message)")
    }
}
