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

    /// Exactly the shape the constructor now produces: the output of
    /// `BinderDefinitionLoader.encode`, which since #60 writes the file on the
    /// server rather than by string concatenation in the page.
    ///
    /// The style is Yams': quotes only where a bare scalar would read back as
    /// something else — `yes` as a bool, `1990` as an int — and non-ASCII text
    /// written as itself. `BinderDefinitionEncodingTests` is what pins it; this
    /// copy is here so the decoder is exercised on the bytes the page hands over.
    /// A title page is a section with a title and no `entries:` key at all (#46).
    private let generatedYAML = """
    binders:
    - name: The "Big" Binder — Sìne Bhàn
      output: the_big_binder.pdf
      sections:
      - title:
        - SVPB Music
        - '2026'
      - toc: true
      - title: What's Inside
        toc: true
      - title: 'Grade 4: Tunes'
        entries:
        - tune: amazing_grace
        - tune: 'yes'
      - title: Massed Bands
        entries:
        - tune: '1990'

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

    /// The page's output replaces `binders.yaml` rather than being appended to
    /// it (#60), and the page says so. Appending it is the hazard the wording
    /// guards against, so this pins that the hazard is at least loud: the second
    /// copy of every binder collides on `output`, and the loader rejects it
    /// instead of quietly building the same PDF twice.
    func testAppendingTheWholeFileToItselfIsRejected() throws {
        let appended = generatedYAML + generatedYAML.split(separator: "\n", maxSplits: 1)[1]

        XCTAssertThrowsError(try BinderDefinitionLoader.decode(appended)) { error in
            XCTAssertTrue("\(error)".contains("is already used by an earlier binder"), "\(error)")
        }
    }

    /// Check hands the decoded file back, so one call serves both Check and
    /// Load: the page rebuilds its editor from this rather than parsing YAML in
    /// the browser (#60).
    func testCheckReturnsTheDecodedFile() async throws {
        let result = try await check(generatedYAML)
        let binder = try XCTUnwrap(result.binders?.first)

        XCTAssertEqual(result.binders?.count, 1)
        XCTAssertEqual(binder.name, "The \"Big\" Binder — Sìne Bhàn")
        XCTAssertEqual(binder.sections.count, 5)
        XCTAssertEqual(binder.sections.flatMap(\.entries).map(\.tune), ["amazing_grace", "yes", "1990"])
    }

    func testCheckReturnsNoFileWhenItIsRejected() async throws {
        let result = try await check("binders: [{ name: A }]")

        XCTAssertFalse(result.valid)
        XCTAssertNil(result.binders)
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

    // MARK: - Writing

    /// The whole point of moving generation off the page (#60): the file the
    /// page will show is the file this endpoint wrote, and it comes back with
    /// the verdict on itself.
    func testWriteReturnsTheFileAndItsVerdict() async throws {
        let result = try await write([
            OfficialBinder(name: "2026 Band Binder", output: "2026_binder.pdf", sections: [
                OfficialBinderSection(title: ["SVPB Music", "2026"]),
                OfficialBinderSection(title: "Grade 4", entries: [OfficialBinderEntry(tune: "amazing_grace")]),
            ]),
        ])

        XCTAssertTrue(result.valid, result.problem ?? "")
        XCTAssertTrue(result.unresolved.isEmpty)
        let yaml = try XCTUnwrap(result.yaml)
        XCTAssertEqual(try BinderDefinitionLoader.decode(yaml).binders.map(\.output), ["2026_binder.pdf"])
    }

    /// What the page posts and what the page is told about it are the same
    /// bytes: the endpoint decodes its own output rather than taking the
    /// request's word for it.
    func testWriteRejectsWhatTheBuildWouldReject() async throws {
        let result = try await write([
            OfficialBinder(name: "Front Matter Only", output: "front.pdf", sections: [
                OfficialBinderSection(title: ["SVPB Music", "2027"]),
            ]),
        ])

        XCTAssertFalse(result.valid)
        XCTAssertNotNil(result.yaml, "the file is still shown, so the pipe major can see what was wrong with it")
        XCTAssertEqual(result.problem,
                       "binders[0] 'Front Matter Only' has no tunes — a binder of title pages alone cannot be assembled")
    }

    func testWriteListsTunesMissingFromTheBranch() async throws {
        let result = try await write([
            OfficialBinder(name: "B", output: "b.pdf", sections: [
                OfficialBinderSection(title: "S", entries: [
                    OfficialBinderEntry(tune: "amazing_grace"),
                    OfficialBinderEntry(tune: "amazing_grase"),
                ]),
            ]),
        ])

        XCTAssertTrue(result.valid, result.problem ?? "")
        XCTAssertEqual(result.unresolved.map(\.tune), ["amazing_grase"])
    }

    /// Load, change nothing, Generate: the file the pipe major gets back says
    /// what the one they pasted said. This is the round trip the whole issue is
    /// about, over the two endpoints the page actually calls.
    func testTheFileSurvivesCheckAndWrite() async throws {
        let original = """
        binders:
          - name: "2027 Band Binder"     # comments are lost, and only comments
            output: 2027_binder.pdf
            pack: true
            sections:
              - title: ["SVPB Music", "2027"]
              - toc: true
              - title: "Massed Bands"
                entries:
                  - tune: amazing_grace
                  - tune: "yes"
                    parts: ["Melody", "Seconds"]
                  - tune: not_in_this_year
                    break: before
              - title: "Parade Tunes"
                entries:
                  - tune: amazing_grace      # the same tune, a second time
          - name: "Solo Book"
            output: solo.pdf
            sections:
              - title: "Solos"
                entries: [{ tune: "1990" }]
        """
        let checked = try await check(original)
        let loaded = try XCTUnwrap(checked.binders)
        let generated = try await write(loaded)
        let written = try XCTUnwrap(generated.yaml)
        let result = try BinderDefinitionLoader.decode(written)

        XCTAssertEqual(result.binders.map(\.name), ["2027 Band Binder", "Solo Book"])
        XCTAssertEqual(result.binders.map(\.pack), [true, false])
        let band = result.binders[0]
        XCTAssertEqual(band.sections.map(\.title.lines),
                       [["SVPB Music", "2027"], [], ["Massed Bands"], ["Parade Tunes"]])
        XCTAssertEqual(band.sections.map(\.toc), [nil, TableOfContentsSpec(), nil, nil])
        XCTAssertEqual(band.sections.flatMap(\.entries).map(\.tune),
                       ["amazing_grace", "yes", "not_in_this_year", "amazing_grace"],
                       "a repeated tune, or one this year's catalogue lacks, was dropped")
        XCTAssertEqual(band.sections[2].entries.map(\.parts),
                       [nil, ["Melody", "Seconds"], nil],
                       "a declared parts list did not survive (#20)")
        XCTAssertEqual(band.sections[2].entries.map(\.pageBreak), [nil, nil, .before])
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

    private func write(_ binders: [OfficialBinder],
                       branch: String = "2026") async throws -> BinderController.BindersYAMLWriteResult {
        var result: BinderController.BindersYAMLWriteResult?
        try await app.test(.POST, "binder-constructor/yaml", beforeRequest: { req in
            try req.content.encode(BinderController.BindersYAMLWriteRequest(branch: branch, binders: binders))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            result = try res.content.decode(BinderController.BindersYAMLWriteResult.self)
        })
        return try XCTUnwrap(result)
    }
}
