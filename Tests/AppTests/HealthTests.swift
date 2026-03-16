import XCTest
import XCTVapor
@testable import App

final class HealthTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testGetHealthReturnsOK() async throws {
        try await app.test(.GET, "health") { res async in
            XCTAssertEqual(res.status, .ok)
        }
    }

    func testGetHealthBodyShape() async throws {
        try await app.test(.GET, "health") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(HealthResponse.self)
            XCTAssertEqual(body.status, .ok)
            XCTAssertEqual(body.version, AppVersion.current)
            XCTAssertTrue(body.branches.isEmpty)
            XCTAssertNil(body.lastBuild)
        }
    }

    func testGetHealthContentTypeIsJSON() async throws {
        try await app.test(.GET, "health") { res async in
            XCTAssertEqual(res.headers.contentType, .json)
        }
    }
}
