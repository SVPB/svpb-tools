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

    /// `pack:` and an entry's `break: before` are how `binders.yaml` asks for short tunes
    /// to share pages (#48). A file that says neither reads as it always did.
    func testDecodesPackingAndPerEntryBreaks() throws {
        let yaml = """
        binders:
          - name: "Packed"
            output: packed.pdf
            pack: true
            sections:
              - title: "Set"
                entries:
                  - tune: a
                  - tune: b
                    break: before
        """
        let binder = try XCTUnwrap(BinderDefinitionLoader.decode(yaml).binders.first)

        XCTAssertTrue(binder.pack)
        XCTAssertEqual(binder.sections[0].entries.map(\.pageBreak), [nil, .before])

        let unchanged = try XCTUnwrap(BinderDefinitionLoader.decode(sampleYAML).binders.first)
        XCTAssertFalse(unchanged.pack)
        XCTAssertEqual(unchanged.sections[0].entries.map(\.pageBreak), [nil, nil])
    }

    /// `before` is the only break there is, so anything else is a typo the pipe major has
    /// to see rather than a line that quietly does nothing.
    func testRejectsAnUnknownBreak() {
        let yaml = """
        binders:
          - name: "Odd"
            output: odd.pdf
            sections:
              - title: "Set"
                entries:
                  - tune: a
                    break: after
        """
        XCTAssertThrowsError(try BinderDefinitionLoader.decode(yaml))
    }

    /// A section with no `entries` is a title page and nothing else (#46), and a
    /// `title` written as a list is one title page of several lines.
    func testTitleOnlySectionsAndMultiLineTitles() throws {
        let yaml = """
        binders:
          - name: "2027 Band Binder"
            output: 2027_binder.pdf
            sections:
              - title: ["SVPB Music", "2027"]
              - title: "G4 Tunes"
                entries: []
              - title: "G4 Medley"
                entries:
                  - tune: g4_medley_2027
        """
        let sections = try BinderDefinitionLoader.decode(yaml).binders[0].sections

        XCTAssertEqual(sections.map(\.title), [["SVPB Music", "2027"], "G4 Tunes", "G4 Medley"])
        XCTAssertEqual(sections.map(\.entries.count), [0, 0, 1])

        // And the spec the assembler builds from carries all three through.
        let spec = try BinderDefinitionLoader.decode(yaml).binders[0].spec(branch: "2027")
        XCTAssertEqual(spec.sections.map(\.titlePage), [["SVPB Music", "2027"], "G4 Tunes", "G4 Medley"])
        XCTAssertEqual(spec.entries.map(\.tuneSlug), ["g4_medley_2027"])
    }

    /// A section may declare itself the binder's table of contents (#47): as a
    /// bare flag, or as a mapping narrowing what it lists. Either way it holds no
    /// tunes, and its title — which it need not have — is a heading rather than a
    /// title page.
    func testDecodesATableOfContents() throws {
        let yaml = """
        binders:
          - name: "2027 Band Binder"
            output: 2027_binder.pdf
            sections:
              - title: ["SVPB Music", "2027"]
              - toc: true
              - title: "What's Inside"
                toc:
                  include: [tunes]
              - title: "G4 Tunes"
                entries:
                  - tune: g4_medley_2027
        """
        let sections = try BinderDefinitionLoader.decode(yaml).binders[0].sections

        XCTAssertEqual(sections.map(\.toc), [nil,
                                             TableOfContentsSpec(),
                                             TableOfContentsSpec(include: [.tunes]),
                                             nil])
        XCTAssertTrue(sections[1].title.isEmpty, "`toc: true` alone needs no title")

        // And the spec the assembler builds from carries the declarations through,
        // with a contents section's title as its heading rather than a title page.
        let spec = try BinderDefinitionLoader.decode(yaml).binders[0].spec(branch: "2027")
        XCTAssertEqual(spec.sections.map(\.titlePage), [["SVPB Music", "2027"], nil, nil, "G4 Tunes"])
        XCTAssertEqual(spec.sections[1].contentsHeading, "Contents")
        XCTAssertEqual(spec.sections[2].contentsHeading, "What's Inside")
    }

    /// `toc: false` is a section saying plainly that it is not one, which is not
    /// the same as a section that is — and it must not turn into one.
    func testTocFalseDeclaresNoTableOfContents() throws {
        let yaml = """
        binders:
          - name: "B"
            output: b.pdf
            sections:
              - title: "S"
                toc: false
                entries:
                  - tune: t
        """
        let sections = try BinderDefinitionLoader.decode(yaml).binders[0].sections
        XCTAssertNil(sections[0].toc)
        XCTAssertEqual(sections[0].entries.map(\.tune), ["t"])
    }

    /// A table of contents is a page of its own: it cannot also be a run of tunes,
    /// and it cannot be asked to list nothing.
    func testRejectsTablesOfContentsThatAreSomethingElseAsWell() {
        let yaml = """
        binders:
          - name: "Muddled"
            output: muddled.pdf
            sections:
              - title: "Contents"
                toc: true
                entries:
                  - tune: stray
              - toc:
                  include: []
              - title: "Real Section"
                entries:
                  - tune: t
        """
        XCTAssertThrowsError(try BinderDefinitionLoader.decode(yaml)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("binders[0].sections[0] is a table of contents and also names 1 tune(s)"), message)
            XCTAssertTrue(message.contains("binders[0].sections[1] is a table of contents that lists nothing"), message)
            XCTAssertFalse(message.contains("sections[2]"), message)
            XCTAssertFalse(message.contains("blank title"), message)
        }
    }

    /// A section is a title page, a run of tunes, or both. A blank title over no
    /// tunes is none of those, and a binder of title pages alone cannot be built.
    func testRejectsSectionsAndBindersThatWouldPrintNothing() {
        let yaml = """
        binders:
          - name: "Titles Only"
            output: titles.pdf
            sections:
              - title: "Front Matter"
              - title: "  "
        """
        XCTAssertThrowsError(try BinderDefinitionLoader.decode(yaml)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("binders[0].sections[1] has a blank title"), message)
            XCTAssertTrue(message.contains("binders[0] 'Titles Only' has no tunes"), message)
        }
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
        // Each binder holds a tune, so the only thing left to object to is its output.
        let section = #"sections: [{ title: "S", entries: [{ tune: t }] }]"#
        let yaml = """
        binders:
          - { name: "A", output: a.pdf, \(section) }
          - { name: "B", output: A.PDF, \(section) }
          - { name: "C", output: ../escape.pdf, \(section) }
          - { name: "D", output: d.txt, \(section) }
          - { name: " ", output: e.pdf, \(section) }
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

            // So does a table of contents, headed or not (#47).
            let withContents = try BinderDefinitionLoader.decode("""
            binders:
              - name: "Contents"
                output: contents.pdf
                sections:
                  - toc: true
                  - title: "What's Inside"
                    toc:
                      include: [tunes]
                  - title: "S"
                    entries:
                      - tune: t
            """)
            try await BinderDefinitionLoader.replaceDefinitions(
                for: "2025", with: withContents.binders, on: app.db)
            let reloaded = try await BinderDefinition.query(on: app.db)
                .filter(\.$branch.$id == "2025").sort(\.$position).all()
            XCTAssertEqual(reloaded[0].sections.map(\.toc),
                           [TableOfContentsSpec(), TableOfContentsSpec(include: [.tunes]), nil])
            XCTAssertEqual(reloaded[0].sections.map(\.title), [[], "What's Inside", "S"])

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
