import Fluent
import XCTVapor
import XCTest
@testable import App

/// The binder constructor writes `binders.yaml` and checks it against the same
/// decoder the build uses (#21).
final class BinderConstructorCheckTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        let branch = Branch(name: "2026")
        try await branch.save(on: app.db)
        for slug in ["amazing_grace", "yes", "1990"] {
            try await Tune(branch: branch, slug: slug, title: slug).save(on: app.db)
        }
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    /// Exactly the shape `generateYAML()` in `binder-constructor.leaf` writes:
    /// every scalar a JSON string, no `parts:`. Slugs that plain YAML would
    /// read as a boolean or a number, and names with quotes and non-ASCII
    /// text, must come through as the strings they were. A title page is
    /// written as a section with a title and no `entries:` key at all (#46).
    private let generatedYAML = """
    binders:
      - name: "The \\"Big\\" Binder — Sìne Bhàn"
        output: "the_big_binder.pdf"
        sections:
          - title: ["SVPB Music", "2026"]
          - toc: true
          - title: "What's Inside"
            toc: true
          - title: "Grade 4: Tunes"
            entries:
              - tune: "amazing_grace"
              - tune: "yes"
          - title: "Massed Bands"
            entries:
              - tune: "1990"

    """

    func testGeneratedShapeDecodes() throws {
        let binder = try XCTUnwrap(BinderDefinitionLoader.decode(generatedYAML).binders.first)

        XCTAssertEqual(binder.name, "The \"Big\" Binder — Sìne Bhàn")
        XCTAssertEqual(binder.output, "the_big_binder.pdf")
        XCTAssertEqual(binder.sections.map(\.title),
                       [["SVPB Music", "2026"], [], "What's Inside", "Grade 4: Tunes", "Massed Bands"])
        // The two shapes the page writes a table of contents in: the bare flag
        // where the heading is the default, and a title beside it where it is not.
        XCTAssertEqual(binder.sections.map(\.toc),
                       [nil, TableOfContentsSpec(), TableOfContentsSpec(), nil, nil])
        XCTAssertEqual(binder.sections.map(\.entries.count), [0, 0, 0, 2, 1],
                       "A title page or a table of contents picked up entries, or a section lost them")
        XCTAssertEqual(binder.sections.flatMap(\.entries).map(\.tune), ["amazing_grace", "yes", "1990"])
        XCTAssertTrue(binder.sections.flatMap(\.entries).allSatisfy { $0.parts == nil })
    }

    /// The page tells the pipe major to paste everything after `binders:` into
    /// an existing file; that has to leave a file the build accepts.
    func testGeneratedBinderPastesIntoExistingFile() throws {
        let existing = """
        binders:
          - name: "2026 Speculative"
            output: 2026_spec.pdf
            sections:
              - title: "Grade 4 Speculative"
                entries:
                  - tune: amazing_grace

        """
        let pasted = generatedYAML.split(separator: "\n", maxSplits: 1)[1]
        let file = try BinderDefinitionLoader.decode(existing + pasted)

        XCTAssertEqual(file.binders.map(\.output), ["2026_spec.pdf", "the_big_binder.pdf"])
    }

    func testCheckAcceptsValidYAML() async throws {
        let result = try await check(generatedYAML)

        XCTAssertTrue(result.valid)
        XCTAssertNil(result.problem)
        XCTAssertTrue(result.unresolved.isEmpty)
    }

    func testCheckReportsWhyTheBuildWouldRejectIt() async throws {
        let yaml = """
        binders:
          - name: "Old shape"
            output: old.pdf
            sections:
              - title: "S"
                entries:
                  - tune_slug: amazing_grace
        """
        let result = try await check(yaml)

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.problem, "binders[0].sections[0].entries[0]: missing key 'tune'")
    }

    func testCheckReportsBadOutputFilenames() async throws {
        // The binder holds a tune, so the output filename is the only thing wrong with it.
        let result = try await check(
            #"binders: [{ name: "A", output: a.txt, sections: [{ title: "S", entries: [{ tune: t }] }] }]"#)

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.problem, "binders[0] output 'a.txt' must be a plain filename ending in .pdf")
    }

    /// Title pages alone are not a binder: assembly needs a tune page, and the
    /// page has to say so before the pipe major commits the file (#46).
    func testCheckRejectsABinderOfTitlePagesAlone() async throws {
        let result = try await check("""
        binders:
          - name: "Front Matter Only"
            output: front.pdf
            sections:
              - title: ["SVPB Music", "2027"]
              - title: "G4 Tunes"
        """)

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.problem,
                       "binders[0] 'Front Matter Only' has no tunes — a binder of title pages alone cannot be assembled")
    }

    /// A title page in an otherwise ordinary binder is accepted, multi-line and all.
    func testCheckAcceptsTitlePagesAlongsideTunes() async throws {
        let result = try await check("""
        binders:
          - name: "2026 Band Binder"
            output: 2026_binder.pdf
            sections:
              - title: ["SVPB Music", "2026"]
              - title: "Massed Bands"
                entries:
                  - tune: amazing_grace
        """)

        XCTAssertTrue(result.valid, "\(result.problem ?? "")")
        XCTAssertTrue(result.unresolved.isEmpty)
    }

    func testCheckListsTunesMissingFromTheBranch() async throws {
        let yaml = """
        binders:
          - name: "B"
            output: b.pdf
            sections:
              - title: "S"
                entries:
                  - tune: amazing_grace
                  - tune: amazing_grase
        """
        let result = try await check(yaml)

        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.unresolved.map(\.tune), ["amazing_grase"])
        XCTAssertEqual(result.unresolved.first?.section, "S")
    }

    // MARK: - Helpers

    private func check(_ yaml: String, branch: String = "2026") async throws -> BinderController.BindersYAMLCheckResult {
        var result: BinderController.BindersYAMLCheckResult?
        try await app.test(.POST, "binder-constructor/check", beforeRequest: { req in
            try req.content.encode(BinderController.BindersYAMLCheckRequest(branch: branch, yaml: yaml))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            result = try res.content.decode(BinderController.BindersYAMLCheckResult.self)
        })
        return try XCTUnwrap(result)
    }
}
