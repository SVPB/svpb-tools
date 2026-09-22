import XCTest
@testable import App

/// `binders.yaml` is written as well as read (#60), so the binder constructor can
/// load a file, edit it, and hand it back.
///
/// The property that matters is not the exact bytes — comments and spacing are
/// lost, because the file is regenerated rather than edited — but that a file
/// decoded, re-encoded, and decoded again says the same thing. These tests
/// assert both: the round trip over a table of fixtures, and one golden file
/// pinning the style so a change in it is a change someone made on purpose.
final class BinderDefinitionEncodingTests: XCTestCase {

    // MARK: - Round trip

    /// Everything `binders.yaml` may say, one fixture at a time. Each is decoded,
    /// written back out, and decoded again; the two structures must agree.
    func testRoundTripPreservesEveryShapeTheFileMayTake() throws {
        for (label, yaml) in Self.fixtures {
            let once = try BinderDefinitionLoader.decode(yaml)
            let written = try BinderDefinitionLoader.encode(once)
            let twice: BindersFile
            do {
                twice = try BinderDefinitionLoader.decode(written)
            } catch {
                XCTFail("\(label): the file we wrote does not decode: \(error)\n\(written)")
                continue
            }
            assertSame(once, twice, label: label, written: written)
        }
    }

    /// The second pass is the one that proves the writer is stable: if encoding
    /// lost something, the third file would differ from the second.
    func testWritingIsIdempotent() throws {
        for (label, yaml) in Self.fixtures {
            let first = try BinderDefinitionLoader.encode(BinderDefinitionLoader.decode(yaml))
            let second = try BinderDefinitionLoader.encode(BinderDefinitionLoader.decode(first))
            XCTAssertEqual(first, second, "\(label): writing the same file twice gave two files")
        }
    }

    // MARK: - Style

    /// The golden file. What is pinned here is the *appearance* of a generated
    /// `binders.yaml`: key order, what is omitted, and how little is quoted.
    ///
    /// Yams quotes only what would otherwise read back as something else — so
    /// `yes` and `1990` keep their quotes while ordinary slugs lose them — and
    /// non-ASCII text is written as itself rather than escaped.
    func testGeneratedFileLooksLikeThis() throws {
        let file = BindersFile(binders: [
            OfficialBinder(
                name: "The \"Big\" Binder — Sìne Bhàn",
                output: "the_big_binder.pdf",
                sections: [
                    OfficialBinderSection(title: ["SVPB Music", "2026"]),
                    OfficialBinderSection(toc: TableOfContentsSpec()),
                    OfficialBinderSection(title: "What's Inside",
                                          toc: TableOfContentsSpec(include: [.tunes])),
                    OfficialBinderSection(title: "Grade 4: Tunes", entries: [
                        OfficialBinderEntry(tune: "amazing_grace"),
                        OfficialBinderEntry(tune: "yes"),
                        OfficialBinderEntry(tune: "1990", parts: ["Melody", "Seconds"]),
                    ]),
                ],
                pack: true
            ),
            OfficialBinder(name: "Parade", output: "parade.pdf", sections: [
                OfficialBinderSection(title: "Parade Tunes", entries: [
                    OfficialBinderEntry(tune: "amazing_grace", pageBreak: .before),
                ]),
            ]),
        ])

        XCTAssertEqual(try BinderDefinitionLoader.encode(file), Self.golden)
    }

    // MARK: - Fixtures

    static let golden = """
    binders:
    - name: The "Big" Binder — Sìne Bhàn
      output: the_big_binder.pdf
      pack: true
      sections:
      - title:
        - SVPB Music
        - '2026'
      - toc: true
      - title: What's Inside
        toc:
          include:
          - tunes
      - title: 'Grade 4: Tunes'
        entries:
        - tune: amazing_grace
        - tune: 'yes'
        - tune: '1990'
          parts:
          - Melody
          - Seconds
    - name: Parade
      output: parade.pdf
      sections:
      - title: Parade Tunes
        entries:
        - tune: amazing_grace
          break: before

    """

    static let fixtures: [(String, String)] = [
        ("the README example", """
        binders:
          - name: "2026 Band Binder"
            output: 2026_binder.pdf
            sections:
              - title: ["SVPB Music", "2026"]
              - toc: true
              - title: "Grade 4 Tunes"
                entries:
                  - tune: g4_medley_2026
                  - tune: Moonstar
        """),
        ("a narrowed table of contents", """
        binders:
          - name: B
            output: b.pdf
            sections:
              - toc:
                  include: [tunes]
              - title: "S"
                entries: [{ tune: a }]
        """),
        ("a multi-line title", """
        binders:
          - name: B
            output: b.pdf
            sections:
              - title: ["SVPB Music", "Season 2027", "Grade 4"]
              - title: "S"
                entries: [{ tune: a }]
        """),
        ("parts on an entry", """
        binders:
          - name: B
            output: b.pdf
            sections:
              - title: "S"
                entries:
                  - tune: a
                    parts: ["Melody", "Seconds"]
        """),
        ("a tune in two sections", """
        binders:
          - name: B
            output: b.pdf
            sections:
              - title: "Massed Bands"
                entries: [{ tune: amazing_grace }]
              - title: "Parade Tunes"
                entries: [{ tune: amazing_grace }]
        """),
        ("a packed binder with a break", """
        binders:
          - name: B
            output: b.pdf
            pack: true
            sections:
              - title: "S"
                entries:
                  - tune: a
                  - tune: b
                    break: before
        """),
        ("slugs that plain YAML would read as bool or int", """
        binders:
          - name: B
            output: b.pdf
            sections:
              - title: "S"
                entries:
                  - tune: "yes"
                  - tune: "no"
                  - tune: "1990"
                  - tune: "on"
        """),
        ("several binders", """
        binders:
          - name: One
            output: one.pdf
            sections:
              - title: "S"
                entries: [{ tune: a }]
          - name: Two
            output: two.pdf
            pack: true
            sections:
              - title: ["Two", "Binder"]
              - toc: true
              - title: "T"
                entries: [{ tune: b }, { tune: c, break: before }]
        """),
    ]

    // MARK: - Helpers

    /// Compares two decoded files field by field, so a failure names what moved
    /// rather than dumping two structures.
    private func assertSame(_ a: BindersFile, _ b: BindersFile, label: String, written: String) {
        let where_ = "\(label):"
        guard a.binders.count == b.binders.count else {
            XCTFail("\(where_) \(a.binders.count) binders became \(b.binders.count)\n\(written)")
            return
        }
        for (x, y) in zip(a.binders, b.binders) {
            XCTAssertEqual(x.name, y.name, where_)
            XCTAssertEqual(x.output, y.output, where_)
            XCTAssertEqual(x.pack, y.pack, "\(where_) pack on '\(x.name)'")
            guard x.sections.count == y.sections.count else {
                XCTFail("\(where_) '\(x.name)' had \(x.sections.count) sections, now \(y.sections.count)\n\(written)")
                continue
            }
            for (s, t) in zip(x.sections, y.sections) {
                XCTAssertEqual(s.title.lines, t.title.lines, "\(where_) section title in '\(x.name)'")
                XCTAssertEqual(s.toc, t.toc, "\(where_) toc in '\(x.name)'")
                XCTAssertEqual(s.entries.map(\.tune), t.entries.map(\.tune),
                               "\(where_) tunes of '\(s.title.display)' in '\(x.name)'")
                XCTAssertEqual(s.entries.map(\.parts), t.entries.map(\.parts),
                               "\(where_) parts of '\(s.title.display)' in '\(x.name)'")
                XCTAssertEqual(s.entries.map(\.pageBreak), t.entries.map(\.pageBreak),
                               "\(where_) breaks of '\(s.title.display)' in '\(x.name)'")
            }
        }
    }
}
