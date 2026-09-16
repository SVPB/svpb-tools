import Fluent
import SQLKit
import XCTVapor
import XCTest
@testable import App

/// `BinderSpec` gained sections after binders had already been stored and shared
/// in the flat shape. Both shapes have to keep decoding.
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
        XCTAssertNil(spec.sections[0].dividerTitle)
        XCTAssertEqual(spec.sections[1].dividerTitle, "Parade Set")
        XCTAssertEqual(spec.entries.map(\.tuneSlug), ["a", "b", "c"])
    }

    /// Stored rows and shared URLs from before sections carry only `entries`.
    func testDecodesFlatShapeAsOneUntitledSection() throws {
        let json = #"{"name":"Old","branch":"2026","entries":[{"tune_slug":"a","parts":["Melody"]},{"tune_slug":"b","parts":["Harmony 1"]}]}"#
        let spec = try JSONDecoder().decode(BinderSpec.self, from: Data(json.utf8))

        XCTAssertEqual(spec.sections.count, 1)
        XCTAssertNil(spec.sections[0].dividerTitle)
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

    /// A blank title means no divider, however it was typed.
    func testBlankTitlesHaveNoDivider() {
        for title in [nil, "", "   ", "\n\t"] {
            XCTAssertNil(BinderSection(title: title, entries: []).dividerTitle, "\(String(describing: title))")
        }
        XCTAssertEqual(BinderSection(title: "  Reels \n", entries: []).dividerTitle, "Reels")
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
