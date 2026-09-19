import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// Removing a branch deletes its rows and its on-disk artifacts — and nothing else.
final class BranchRemovalTests: XCTestCase {

    var app: Application!
    var workspace: URL!
    var service: BuildService!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("branch-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        service = BuildService(
            gitService: GitService(repoURL: "", workspaceBase: workspace),
            boxService: app.boxService,
            slackService: app.slackService,
            binderService: app.binderService,
            musicWorkspacePath: workspace.path)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(at: workspace)
    }

    func testRemovesRowsAndDirectoriesForThatBranchOnly() async throws {
        try await seedBranch("2019", tunes: ["march", "reel"])
        try await seedBranch("2026", tunes: ["march"])
        try writeFile("2019/march.abc", bytes: 100)
        try writeFile("2019/.git/HEAD", bytes: 20)
        try writeFile("output/2019/march000.svg", bytes: 300)
        try writeFile("output/2019/march.pdf", bytes: 80)
        try writeFile("2026/march.abc", bytes: 1)
        try writeFile("output/2026/march.pdf", bytes: 1)
        try writeFile("binders/\(UUID().uuidString).pdf", bytes: 1)

        let summary = try await service.removeBranch("2019", db: app.db, logger: app.logger)

        XCTAssertEqual(summary, BranchRemovalSummary(
            branch: "2019", tunes: 2, parts: 4, builds: 1, binderDefinitions: 1, boxUploads: 1,
            directories: ["2019", "output/2019"], bytes: 500))

        let branch2019 = try await Branch.find("2019", on: app.db)
        XCTAssertNil(branch2019)
        let tunes2019 = try await Tune.query(on: app.db).filter(\.$branch.$id == "2019").count()
        XCTAssertEqual(tunes2019, 0)
        let builds2019 = try await Build.query(on: app.db).filter(\.$branch.$id == "2019").count()
        XCTAssertEqual(builds2019, 0)
        let binders2019 = try await BinderDefinition.query(on: app.db).filter(\.$branch.$id == "2019").count()
        XCTAssertEqual(binders2019, 0)
        let uploads2019 = try await BoxUpload.query(on: app.db).filter(\.$branch.$id == "2019").count()
        XCTAssertEqual(uploads2019, 0, "The record of what reached Box goes with the branch")
        let uploads2026 = try await BoxUpload.query(on: app.db).filter(\.$branch.$id == "2026").count()
        XCTAssertEqual(uploads2026, 1, "Another branch's record is untouched")
        let allParts = try await Part.query(on: app.db).count()
        XCTAssertEqual(allParts, 2, "Only 2026's parts remain")
        XCTAssertFalse(exists("2019"))
        XCTAssertFalse(exists("output/2019"))

        // The other branch, the output root, and personalised binders are untouched.
        let branch2026 = try await Branch.find("2026", on: app.db)
        XCTAssertNotNil(branch2026)
        let tunes2026 = try await Tune.query(on: app.db).filter(\.$branch.$id == "2026").count()
        XCTAssertEqual(tunes2026, 1)
        XCTAssertTrue(exists("2026/march.abc"))
        XCTAssertTrue(exists("output/2026/march.pdf"))
        XCTAssertTrue(exists("binders"))
    }

    func testRowsWithoutDirectoriesSucceeds() async throws {
        try await seedBranch("2019", tunes: ["march"])

        let summary = try await service.removeBranch("2019", db: app.db, logger: app.logger)

        XCTAssertEqual(summary.tunes, 1)
        XCTAssertEqual(summary.directories, [])
        XCTAssertEqual(summary.bytes, 0)
    }

    func testDirectoriesWithoutRowsSucceeds() async throws {
        try writeFile("output/2019/march.pdf", bytes: 10)

        let summary = try await service.removeBranch("2019", db: app.db, logger: app.logger)

        XCTAssertEqual(summary.tunes, 0)
        XCTAssertEqual(summary.directories, ["output/2019"])
        XCTAssertFalse(exists("output/2019"))
    }

    func testUnknownBranchIsNotFound() async throws {
        await assertAbort(.notFound) {
            _ = try await self.service.removeBranch("1999", db: self.app.db, logger: self.app.logger)
        }
    }

    func testRejectsNamesThatEscapeOrCollideWithTheWorkspace() async throws {
        try writeFile("output/2026/march.pdf", bytes: 1)
        try writeFile("binders/x.pdf", bytes: 1)

        for name in ["", ".", "..", "../etc", "2019/..", "/etc", "a//b", "output", "binders", "binders/x", "a\\b"] {
            await assertAbort(.badRequest, name) {
                _ = try await self.service.removeBranch(name, db: self.app.db, logger: self.app.logger)
            }
        }
        XCTAssertTrue(exists("output/2026/march.pdf"))
        XCTAssertTrue(exists("binders/x.pdf"))
    }

    func testRefusesWhileTheBranchIsBuilding() async throws {
        try await seedBranch("2026", tunes: ["march"])
        let started = await service.beginBuild(branch: "2026")
        XCTAssertTrue(started)

        await assertAbort(.conflict) {
            _ = try await self.service.removeBranch("2026", db: self.app.db, logger: self.app.logger)
        }
        let stillThere = try await Branch.find("2026", on: app.db)
        XCTAssertNotNil(stillThere)

        await service.endBuild(branch: "2026")
        let summary = try await service.removeBranch("2026", db: app.db, logger: app.logger)
        XCTAssertEqual(summary.tunes, 1)
    }

    func testOverlappingBuildsAllHaveToFinish() async throws {
        try await seedBranch("2026", tunes: [])
        _ = await service.beginBuild(branch: "2026")
        _ = await service.beginBuild(branch: "2026")
        await service.endBuild(branch: "2026")

        await assertAbort(.conflict) {
            _ = try await self.service.removeBranch("2026", db: self.app.db, logger: self.app.logger)
        }
    }

    func testRouteRequiresAnAdminSession() async throws {
        try await Branch(name: "2019").save(on: app.db)

        try await app.test(.DELETE, "admin/branches/2019") { res async in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/admin/login")
        }
        let branch = try await Branch.find("2019", on: app.db)
        XCTAssertNotNil(branch)
    }

    // MARK: - Helpers

    /// A branch with one successful build, one binder definition, and two parts per tune.
    private func seedBranch(_ name: String, tunes: [String]) async throws {
        let branch = Branch(name: name)
        try await branch.save(on: app.db)
        for slug in tunes {
            let tune = try Tune(branch: branch, slug: slug, title: slug)
            try await tune.save(on: app.db)
            try await Part(tune: tune, name: "Melody", svgPaths: []).save(on: app.db)
            try await Part(tune: tune, name: "Seconds", svgPaths: []).save(on: app.db)
        }
        try await Build(branch: branch, status: .success).save(on: app.db)
        let binder = OfficialBinder(name: "\(name) Binder", output: "\(name).pdf", sections: [])
        try await BinderDefinitionLoader.replaceDefinitions(for: name, with: [binder], on: app.db)
        try await BoxUpload(branch: name, filename: "\(name).pdf",
                            localPath: "/output/\(name)/binders/\(name).pdf",
                            contentHash: "deadbeef").create(on: app.db)
    }

    private func writeFile(_ relative: String, bytes: Int) throws {
        let url = workspace.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: workspace.appendingPathComponent(relative).path)
    }

    private func assertAbort(
        _ status: HTTPResponseStatus, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(status) for '\(message)'", file: file, line: line)
        } catch let abort as AbortError {
            XCTAssertEqual(abort.status, status, "'\(message)': \(abort.reason)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error for '\(message)': \(error)", file: file, line: line)
        }
    }
}
