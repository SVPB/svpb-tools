import Fluent
import SQLKit
import XCTVapor
import XCTest
@testable import App

/// `BinderSpec` gained sections after binders had already been stored and shared
/// in the flat shape, and titles became multi-line after that (#46). Every shape
/// written so far has to keep decoding, and a one-line title has to keep encoding
/// as the bare string it was written as.
final class BinderSpecTests: XCTestCase {

    func testDecodesSections() throws {
        let json = #"""
        {"name":"B","branch":"2026","sections":[
          {"title":null,"entries":[{"tune_slug":"a","parts":["Melody"]}]},
          {"title":"Parade Set","entries":[{"tune_slug":"b","parts":["Melody"]},{"tune_slug":"c","parts":["Seconds"]}]}
        ]}
        """#
        let spec = try JSONDecoder().decode(BinderSpec.self, from: Data(json.utf8))

        XCTAssertEqual(spec.sections.count, 2)
        XCTAssertNil(spec.sections[0].titlePage)
        XCTAssertEqual(spec.sections[1].titlePage, "Parade Set")
        XCTAssertEqual(spec.entries.map(\.tuneSlug), ["a", "b", "c"])
    }

    /// A title page is a section that holds no tunes (#46), and the front matter
    /// of a binder is however many of those it opens with.
    func testDecodesTitleOnlySections() throws {
        let json = #"""
        {"name":"B","branch":"2027","sections":[
          {"title":["SVPB Music","2027"],"entries":[]},
          {"title":"G4 Tunes","entries":[]},
          {"title":"G4 Medley","entries":[{"tune_slug":"g4_medley_2027","parts":[]}]}
        ]}
        """#
        let spec = try JSONDecoder().decode(BinderSpec.self, from: Data(json.utf8))

        XCTAssertEqual(spec.sections.map(\.titlePage),
                       [["SVPB Music", "2027"], "G4 Tunes", "G4 Medley"])
        XCTAssertEqual(spec.sections.map(\.entries.count), [0, 0, 1])
        XCTAssertEqual(spec.entries.map(\.tuneSlug), ["g4_medley_2027"])
    }

    /// A multi-line title is written as a list and a one-line title as a string,
    /// and both come back as the same type.
    func testTitleDecodesFromAStringOrAList() throws {
        let one = try JSONDecoder().decode(BinderTitle.self, from: Data(#""Parade Set""#.utf8))
        XCTAssertEqual(one.pageLines, ["Parade Set"])

        let two = try JSONDecoder().decode(BinderTitle.self, from: Data(#"["SVPB Music","2027"]"#.utf8))
        XCTAssertEqual(two.pageLines, ["SVPB Music", "2027"])
        XCTAssertEqual(two.display, "SVPB Music / 2027")
    }

    /// A one-line title has to encode as the bare string it arrived as: stored
    /// `binder_requests` rows and shared URLs written before #46 must not change
    /// shape just by being read and written back.
    func testOneLineTitleEncodesAsAString() throws {
        let encoder = JSONEncoder()
        XCTAssertEqual(String(decoding: try encoder.encode(BinderTitle(["Parade Set"])), as: UTF8.self),
                       #""Parade Set""#)
        XCTAssertEqual(String(decoding: try encoder.encode(BinderTitle(["SVPB Music", "2027"])), as: UTF8.self),
                       #"["SVPB Music","2027"]"#)

        let spec = BinderSpec(name: "B", branch: "2027", sections: [
            BinderSection(title: ["SVPB Music", "2027"], entries: []),
            BinderSection(title: "Parade", entries: [BinderEntry(tuneSlug: "a", parts: [])]),
        ])
        let decoded = try JSONDecoder().decode(BinderSpec.self, from: try encoder.encode(spec))
        XCTAssertEqual(decoded.sections.map(\.title), spec.sections.map(\.title))
    }

    /// Stored rows and shared URLs from before sections carry only `entries`.
    func testDecodesFlatShapeAsOneUntitledSection() throws {
        let json = #"{"name":"Old","branch":"2026","entries":[{"tune_slug":"a","parts":["Melody"]},{"tune_slug":"b","parts":["Harmony 1"]}]}"#
        let spec = try JSONDecoder().decode(BinderSpec.self, from: Data(json.utf8))

        XCTAssertEqual(spec.sections.count, 1)
        XCTAssertNil(spec.sections[0].titlePage)
        XCTAssertEqual(spec.entries.map(\.tuneSlug), ["a", "b"])
        XCTAssertEqual(spec.entries[1].parts, ["Harmony 1"])
    }

    func testRejectsSpecWithNeitherShape() {
        let json = #"{"name":"B","branch":"2026"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(BinderSpec.self, from: Data(json.utf8)))
    }

    func testEncodesSectionsOnly() throws {
        let spec = BinderSpec(name: "B", branch: "2026", sections: [
            BinderSection(title: "Parade", entries: [BinderEntry(tuneSlug: "a", parts: ["Melody"])]),
        ])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any]

        XCTAssertNotNil(object?["sections"])
        XCTAssertNil(object?["entries"], "Encoding should not write the legacy key")
        let decoded = try JSONDecoder().decode(BinderSpec.self, from: JSONEncoder().encode(spec))
        XCTAssertEqual(decoded.sections.first?.title, "Parade")
    }

    /// A spec written before a binder could carry a table of contents encodes
    /// exactly as it did: `toc` appears only where there is one, and where there
    /// is one that lists everything it is the bare `true` the builder writes.
    func testTocIsWrittenOnlyWhereThereIsOne() throws {
        let spec = BinderSpec(name: "B", branch: "2026", sections: [
            BinderSection(title: nil, entries: [], toc: TableOfContentsSpec()),
            BinderSection(title: "Narrow", entries: [], toc: TableOfContentsSpec(include: [.tunes])),
            BinderSection(title: "Parade", entries: [BinderEntry(tuneSlug: "a", parts: ["Melody"])]),
        ])
        let data = try JSONEncoder().encode(spec)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sections = try XCTUnwrap(object?["sections"] as? [[String: Any]])

        XCTAssertEqual(sections[0]["toc"] as? Bool, true)
        XCTAssertEqual((sections[1]["toc"] as? [String: Any])?["include"] as? [String], ["tunes"])
        XCTAssertNil(sections[2]["toc"], "A section that is not a table of contents said so anyway")

        let decoded = try JSONDecoder().decode(BinderSpec.self, from: data)
        XCTAssertEqual(decoded.sections.map(\.toc),
                       [TableOfContentsSpec(), TableOfContentsSpec(include: [.tunes]), nil])
        // A contents section's title is its heading, never a title page.
        XCTAssertEqual(decoded.sections.map(\.titlePage), [nil, nil, "Parade"])
        XCTAssertEqual(decoded.sections.prefix(2).map(\.contentsHeading), ["Contents", "Narrow"])
    }

    /// The shapes a hand-written or older spec may use to decline one.
    func testTocIsAbsentUnlessDeclared() throws {
        for written in ["", #""toc":null,"#, #""toc":false,"#] {
            let json = #"{"name":"B","branch":"2026","sections":[{\#(written)"title":"S","entries":[]}]}"#
            let spec = try JSONDecoder().decode(BinderSpec.self, from: Data(json.utf8))
            XCTAssertNil(spec.sections[0].toc, "'\(written)' declared a table of contents")
            XCTAssertEqual(spec.sections[0].titlePage, "S")
        }
    }

    /// `include` is normalised, so two ways of writing the same listing are the
    /// same listing.
    func testListingsAreNormalised() {
        XCTAssertEqual(TableOfContentsSpec(include: [.tunes, .sections]), TableOfContentsSpec())
        XCTAssertEqual(TableOfContentsSpec(include: [.tunes, .tunes]).include, [.tunes])
        XCTAssertTrue(TableOfContentsSpec(include: []).isEmpty)
        XCTAssertFalse(TableOfContentsSpec().isEmpty)
        XCTAssertTrue(TableOfContentsSpec().listsSections && TableOfContentsSpec().listsTunes)
    }

    /// A blank title means no title page, however it was typed — including a
    /// list whose lines are all blank.
    func testBlankTitlesHaveNoTitlePage() {
        let blanks: [BinderTitle?] = [nil, "", "   ", "\n\t", [], ["", "  "]]
        for title in blanks {
            XCTAssertNil(BinderSection(title: title, entries: []).titlePage, "\(String(describing: title))")
        }
        XCTAssertEqual(BinderSection(title: "  Reels \n", entries: []).titlePage, "Reels")
        XCTAssertEqual(BinderSection(title: ["  SVPB   Music ", "", " 2027"], entries: []).titlePage,
                       ["SVPB Music", "2027"], "Blank lines and runs of spaces survived")
    }

    /// The same compatibility, through the database column rather than JSON in
    /// memory: a `binder_requests` row written before sections still loads.
    func testStoredFlatDefinitionStillLoads() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            let sql = try XCTUnwrap(app.db as? any SQLDatabase)
            let id = UUID()
            let definition = #"{"name":"Old","branch":"2026","entries":[{"tune_slug":"a","parts":["Melody"]}]}"#
            try await sql.raw("""
                INSERT INTO binder_requests (id, definition, created_at)
                VALUES (\(bind: id), \(bind: definition), \(bind: Date()))
                """).run()

            let request = try await BinderRequest.find(id, on: app.db)
            XCTAssertEqual(request?.definition.sections.count, 1)
            XCTAssertEqual(request?.definition.entries.first?.tuneSlug, "a")
        } catch {
            XCTFail("\(error)")
        }
        try await app.asyncShutdown()
    }
}
