import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// The organisation's names: an admin's setting over the environment over nothing, and
/// every page showing "{short} TNG", or plain "TNG" with none set (#89).
final class OrgNameTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        // Whatever the machine running the tests has in its environment.
        app.orgProfile.replace(with: OrgNames())
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    // MARK: - Precedence

    func testNothingSetIsNeutral() async throws {
        let resolved = try await OrgProfile.resolve(on: app.db, environment: { _ in nil })
        XCTAssertEqual(resolved.names, OrgNames())
        XCTAssertEqual(resolved.nameSource, .builtIn)
        XCTAssertEqual(resolved.shortNameSource, .builtIn)
        XCTAssertEqual(resolved.names.siteName, "TNG")
        XCTAssertEqual(resolved.names.subtitle, "Tools Next Generation")
    }

    func testTheEnvironmentSetsTheNames() async throws {
        let env = ["ORG_NAME": " Silicon Valley Pipe Band ", "ORG_SHORT_NAME": "SVPB"]
        let resolved = try await OrgProfile.resolve(on: app.db, environment: { env[$0] })
        XCTAssertEqual(resolved.names, OrgNames(name: "Silicon Valley Pipe Band", shortName: "SVPB"))
        XCTAssertEqual(resolved.nameSource, .environment)
        XCTAssertEqual(resolved.shortNameSource, .environment)
        XCTAssertEqual(resolved.names.siteName, "SVPB TNG")
        XCTAssertEqual(resolved.names.subtitle, "Silicon Valley Pipe Band · Tools Next Generation")
    }

    func testAnAdminSettingOverridesTheEnvironment() async throws {
        try await Setting.set(Setting.orgShortName, to: "CPB", on: app.db)
        let env = ["ORG_NAME": "Silicon Valley Pipe Band", "ORG_SHORT_NAME": "SVPB"]
        let resolved = try await OrgProfile.resolve(on: app.db, environment: { env[$0] })
        XCTAssertEqual(resolved.names, OrgNames(name: "Silicon Valley Pipe Band", shortName: "CPB"))
        XCTAssertEqual(resolved.nameSource, .environment)
        XCTAssertEqual(resolved.shortNameSource, .admin)
    }

    /// `.env.example` leaves both names empty; empty is unset, not a blank name.
    func testBlankValuesCountAsUnset() async throws {
        try await Setting.set(Setting.orgName, to: "  ", on: app.db)
        let env = ["ORG_NAME": "", "ORG_SHORT_NAME": "  "]
        let resolved = try await OrgProfile.resolve(on: app.db, environment: { env[$0] })
        XCTAssertEqual(resolved.names, OrgNames())
        XCTAssertEqual(resolved.nameSource, .builtIn)
    }

    // MARK: - Pages

    func testPagesSayJustTNGWithNoNameSet() async throws {
        let home = try await page("")
        XCTAssertTrue(home.contains("<title>TNG</title>"), home)
        XCTAssertTrue(home.contains("<footer>TNG v"), home)
        XCTAssertFalse(home.contains("SVPB"), home)

        let login = try await page("admin/login")
        XCTAssertTrue(login.contains("<title>Sign In — TNG</title>"), login)
        XCTAssertTrue(login.contains("<h1>TNG Admin</h1>"), login)
        XCTAssertTrue(login.contains("Tools Next Generation · v"), login)
        XCTAssertFalse(login.contains("·  ·"), login)
        XCTAssertFalse(login.contains("SVPB"), login)
    }

    func testPagesShowTheConfiguredNames() async throws {
        app.orgProfile.replace(with: OrgNames(name: "Silicon Valley Pipe Band", shortName: "SVPB"))

        let home = try await page("")
        XCTAssertTrue(home.contains("<title>SVPB TNG</title>"), home)
        XCTAssertTrue(home.contains("<img src=\"/img/logo\" alt=\"\">SVPB TNG</h1>"), home)
        XCTAssertTrue(home.contains("<footer>SVPB TNG v"), home)

        let login = try await page("admin/login")
        XCTAssertTrue(login.contains("<title>Sign In — SVPB TNG</title>"), login)
        XCTAssertTrue(login.contains("<h1>SVPB TNG Admin</h1>"), login)
        XCTAssertTrue(login.contains("Silicon Valley Pipe Band · Tools Next Generation · v"), login)
    }

    /// The tag's output is escaped like any other value.
    func testANameIsEscaped() async throws {
        app.orgProfile.replace(with: OrgNames(shortName: "<b>&"))
        let home = try await page("")
        XCTAssertTrue(home.contains("&lt;b&gt;&amp; TNG"), home)
        XCTAssertFalse(home.contains("<b>& TNG"), home)
    }

    // MARK: - The admin page

    func testSavingNamesPutsThemInForceAtOnce() async throws {
        let cookies = try await signInAsAdmin()
        try await app.test(.PUT, "admin/org/names", beforeRequest: { req async throws in
            req.headers.cookie = cookies
            try req.content.encode(["name": "Silicon Valley Pipe Band", "shortName": " SVPB "])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .noContent)
        })

        XCTAssertEqual(app.orgProfile.names, OrgNames(name: "Silicon Valley Pipe Band", shortName: "SVPB"))
        let stored = try await Setting.value(for: Setting.orgShortName, on: app.db)
        XCTAssertEqual(stored, "SVPB")
        let home = try await page("")
        XCTAssertTrue(home.contains("<title>SVPB TNG</title>"), home)
    }

    /// Clearing a name removes the override, back to whatever `.env` says.
    func testSavingABlankNameClearsTheOverride() async throws {
        try await Setting.set(Setting.orgShortName, to: "SVPB", on: app.db)
        let cookies = try await signInAsAdmin()
        try await app.test(.PUT, "admin/org/names", beforeRequest: { req async throws in
            req.headers.cookie = cookies
            try req.content.encode(["name": "", "shortName": "  "])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .noContent)
        })

        let stored = try await Setting.value(for: Setting.orgShortName, on: app.db)
        XCTAssertNil(stored)
    }

    func testTheOrganisationPageRendersForAnAdmin() async throws {
        let cookies = try await signInAsAdmin()
        try await app.test(.GET, "admin/org", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains("Header logo"), res.body.string)
            XCTAssertTrue(res.body.string.contains("<title>Organisation — TNG</title>"), res.body.string)
        })
    }

    func testTheOrganisationPageIsForAdminsOnly() async throws {
        try await app.test(.GET, "admin/org") { res async in
            XCTAssertEqual(res.status, .seeOther)
        }
        try await app.test(.PUT, "admin/org/names", beforeRequest: { req async throws in
            try req.content.encode(["shortName": "Mallory"])
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .seeOther)
        })
        XCTAssertNil(app.orgProfile.names.shortName)
    }

    // MARK: - Helpers

    private func page(_ path: String) async throws -> String {
        var html = ""
        try await app.test(.GET, path) { res async in
            XCTAssertEqual(res.status, .ok)
            html = res.body.string
        }
        return html
    }

    private func signInAsAdmin() async throws -> HTTPCookies {
        try await OrgTestSupport.signInAsAdmin(app)
    }
}

/// Shared by the organisation tests.
enum OrgTestSupport {

    /// Signs in as an admin the way a real admin does — by redeeming a magic link — and
    /// returns the session cookie.
    static func signInAsAdmin(_ app: Application) async throws -> HTTPCookies {
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

    /// The repository's root, for fixtures kept outside `Tests/`.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()
}
