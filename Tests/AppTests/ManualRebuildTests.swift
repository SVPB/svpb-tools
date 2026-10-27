import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// The dashboard's rebuild button runs the webhook's full build, and builds of one branch
/// never interleave however they were asked for (#11).
final class ManualRebuildTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    // MARK: - Route

    func testRouteRequiresAnAdminSession() async throws {
        try await Branch(name: "2026").save(on: app.db)

        try await app.test(.POST, "admin/branches/2026/rebuild") { res async in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin/login")
        }
        let builds = try await Build.query(on: app.db).count()
        XCTAssertEqual(builds, 0)
    }

    func testUnknownBranchIsNotFound() async throws {
        let cookies = try await signInAsAdmin()

        try await app.test(.POST, "admin/branches/nonesuch/rebuild", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    /// The button cannot queue a second full distribution behind one already under way.
    func testRefusedWhileTheBranchIsBuilding() async throws {
        try await Branch(name: "2026").save(on: app.db)
        let cookies = try await signInAsAdmin()
        _ = await app.buildService.beginBuild(branch: "2026")

        try await app.test(.POST, "admin/branches/2026/rebuild", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .conflict)
        })

        await app.buildService.endBuild(branch: "2026")
        let builds = try await Build.query(on: app.db).count()
        XCTAssertEqual(builds, 0)
    }

    // MARK: - Serialisation

    func testASecondBuildOfTheBranchWaitsForTheFirst() async throws {
        let service = app.buildService
        let order = Recorder()

        await service.acquirePipeline(branch: "2026")
        let second = Task {
            await service.acquirePipeline(branch: "2026")
            await order.append("second")
            await service.releasePipeline(branch: "2026")
        }
        try await Task.sleep(for: .milliseconds(100))
        await order.append("first")
        await service.releasePipeline(branch: "2026")
        await second.value

        let events = await order.events
        XCTAssertEqual(events, ["first", "second"])
    }

    func testWaitingBuildsRunInTheOrderTheyArrived() async throws {
        let service = app.buildService
        let order = Recorder()

        await service.acquirePipeline(branch: "2026")
        var waiting: [Task<Void, Never>] = []
        for name in ["a", "b", "c"] {
            waiting.append(Task {
                await service.acquirePipeline(branch: "2026")
                await order.append(name)
                await service.releasePipeline(branch: "2026")
            })
            // Each must be queued before the next is started.
            try await Task.sleep(for: .milliseconds(50))
        }
        await service.releasePipeline(branch: "2026")
        for task in waiting { await task.value }

        let events = await order.events
        XCTAssertEqual(events, ["a", "b", "c"])
    }

    func testOtherBranchesAreNotHeldUp() async throws {
        let service = app.buildService

        await service.acquirePipeline(branch: "2026")
        // Would never return if it waited on 2026.
        await service.acquirePipeline(branch: "2019")
        await service.releasePipeline(branch: "2019")
        await service.releasePipeline(branch: "2026")
    }

    // MARK: - Helpers

    private actor Recorder {
        var events: [String] = []
        func append(_ event: String) { events.append(event) }
    }

    /// Signs in as an admin by redeeming a magic link, and returns the session cookie.
    private func signInAsAdmin() async throws -> HTTPCookies {
        let user = User(slackUserId: "U_ADMIN", displayName: "Admin", role: .admin)
        try await user.save(on: app.db)
        let token = LoginToken(slackUserId: "U_ADMIN", expiresAt: Date().addingTimeInterval(600))
        try await token.save(on: app.db)

        var cookies: HTTPCookies = [:]
        try await app.test(.GET, "auth/token/\(token.id!.uuidString)") { res async in
            XCTAssertEqual(res.status, .seeOther)
            cookies = res.headers.setCookie ?? [:]
        }
        return cookies
    }
}
