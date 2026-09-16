import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// `binders.yaml` is read on every build: decoded, checked, validated against the
/// catalogue, and stored as `BinderDefinition` records.
final class BinderDefinitionTests: XCTestCase {

    private let sampleYAML = """
    # binders.yaml
    binders:
      - name: "2026 Band Binder"
        output: 2026_binder.pdf
        sections:
          - title: "Grade 4 Tunes"
            entries:
              - tune: g4_medley_2026
              - tune: Moonstar
                parts: ["Melody", "Seconds"]
          - title: "Massed Bands"
            entries:
              - tune: amazing_grace
      - name: "2026 Speculative"
        output: 2026_spec.pdf
        sections:
          - title: "Grade 4 Speculative"
            entries:
              - tune: victoria_harbour
    """

    // MARK: - Decoding

    func testDecodesBindersSectionsAndEntries() throws {
        let file = try BinderDefinitionLoader.decode(sampleYAML)

        XCTAssertEqual(file.binders.map(\.name), ["2026 Band Binder", "2026 Speculative"])
        XCTAssertEqual(file.binders.map(\.output), ["2026_binder.pdf", "2026_spec.pdf"])
        let sections = file.binders[0].sections
        XCTAssertEqual(sections.map(\.title), ["Grade 4 Tunes", "Massed Bands"])
        XCTAssertEqual(sections[0].entries.map(\.tune), ["g4_medley_2026", "Moonstar"])
    }

    /// `parts` is ignored by assembly for now (#20) but must survive decoding.
    func testPartsAreOptionalAndKept() throws {
        let entries = try BinderDefinitionLoader.decode(sampleYAML).binders[0].sections[0].entries

        XCTAssertNil(entries[0].parts)
        XCTAssertEqual(entries[1].parts, ["Melody", "Seconds"])
    }

    func testMissingKeyNamesItsPath() {
        let yaml = """
        binders:
          - name: "B"
            output: b.pdf
            sections:
              - title: "S"
                entries:
                  - tune_slug: oops
        """
        XCTAssertThrowsError(try BinderDefinitionLoader.decode(yaml)) { error in
            XCTAssertEqual("\(error)", "binders[0].sections[0].entries[0]: missing key 'tune'")
        }
    }

    /// A syntax error has to say where it is, not just that the YAML is invalid.
    func testSyntaxErrorGivesLineAndColumn() {
        XCTAssertThrowsError(try BinderDefinitionLoader.decode("binders: [\n  - name: \"unclosed")) { error in
            XCTAssertTrue("\(error)".hasPrefix("2:3: "), "\(error)")
        }
    }

    func testRejectsUnusableOutputs() {
        let yaml = """
        binders:
          - { name: "A", output: a.pdf, sections: [] }
          - { name: "B", output: A.PDF, sections: [] }
          - { name: "C", output: ../escape.pdf, sections: [] }
          - { name: "D", output: d.txt, sections: [] }
          - { name: " ", output: e.pdf, sections: [] }
        """
        XCTAssertThrowsError(try BinderDefinitionLoader.decode(yaml)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("binders[1] output 'A.PDF' is already used"), message)
            XCTAssertTrue(message.contains("binders[2] output '../escape.pdf'"), message)
            XCTAssertTrue(message.contains("binders[3] output 'd.txt'"), message)
            XCTAssertTrue(message.contains("binders[4] has a blank name"), message)
            XCTAssertFalse(message.contains("binders[0]"), message)
        }
    }

    // MARK: - Reading from a branch

    func testAbsentFileIsNotAnError() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(try BinderDefinitionLoader.load(from: dir))
    }

    func testLoadsFileFromBranchRoot() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try sampleYAML.write(to: dir.appendingPathComponent("binders.yaml"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try BinderDefinitionLoader.load(from: dir)?.binders.count, 2)
    }

    // MARK: - Catalogue validation

    func testReportsUnresolvedTunesInFileOrder() throws {
        let file = try BinderDefinitionLoader.decode(sampleYAML)
        let unresolved = BinderDefinitionLoader.unresolvedEntries(
            in: file, catalogueSlugs: ["g4_medley_2026", "amazing_grace"])

        XCTAssertEqual(unresolved, [
            .init(binder: "2026 Band Binder", section: "Grade 4 Tunes", tune: "Moonstar"),
            .init(binder: "2026 Speculative", section: "Grade 4 Speculative", tune: "victoria_harbour"),
        ])
    }

    // MARK: - Persistence

    func testReplacesDefinitionsForOneBranchOnly() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await Branch(name: "2025").save(on: app.db)
            try await Branch(name: "2026").save(on: app.db)

            let file = try BinderDefinitionLoader.decode(sampleYAML)
            try await BinderDefinitionLoader.replaceDefinitions(for: "2025", with: file.binders, on: app.db)
            try await BinderDefinitionLoader.replaceDefinitions(for: "2026", with: file.binders, on: app.db)

            // A rebuild of 2026 whose file now declares only the second binder.
            try await BinderDefinitionLoader.replaceDefinitions(
                for: "2026", with: [file.binders[1]], on: app.db)

            let stored2026 = try await BinderDefinition.query(on: app.db)
                .filter(\.$branch.$id == "2026").sort(\.$position).all()
            XCTAssertEqual(stored2026.map(\.output), ["2026_spec.pdf"])
            XCTAssertEqual(stored2026.map(\.position), [0])

            let stored2025 = try await BinderDefinition.query(on: app.db)
                .filter(\.$branch.$id == "2025").sort(\.$position).all()
            XCTAssertEqual(stored2025.map(\.name), ["2026 Band Binder", "2026 Speculative"])

            // Sections, including `parts`, round-trip through the JSON column.
            let entries = stored2025[0].sections[0].entries
            XCTAssertEqual(entries.map(\.tune), ["g4_medley_2026", "Moonstar"])
            XCTAssertNil(entries[0].parts)
            XCTAssertEqual(entries[1].parts, ["Melody", "Seconds"])

            // An absent or rejected file stores nothing.
            try await BinderDefinitionLoader.replaceDefinitions(for: "2026", with: [], on: app.db)
            let remaining = try await BinderDefinition.query(on: app.db)
                .filter(\.$branch.$id == "2026").count()
            XCTAssertEqual(remaining, 0)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binder-definitions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
