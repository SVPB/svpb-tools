import XCTest
import XCTVapor
@testable import App

/// Renders the two binder pages end to end.
///
/// Both pages are assembled from the same Leaf partials and the same
/// `tune-selector.js` module, so a broken partial reference or a renamed
/// element ID breaks them silently in the browser rather than at build time.
/// These tests fail instead.
final class BinderPageTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    /// Element IDs the shared component looks up by name.
    private let sharedElementIDs = [
        "sel-branch", "binder-name", "search-tunes",
        "tune-list", "binder-entries", "empty-msg", "add-section",
    ]

    func testConstructorPageRenders() async throws {
        try await app.test(.GET, "binder-constructor") { res async in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            for id in self.sharedElementIDs {
                XCTAssertTrue(html.contains("id=\"\(id)\""), "missing #\(id)")
            }
            XCTAssertTrue(html.contains("/js/tune-selector.js"))
            XCTAssertTrue(html.contains("Selected Entries"))
            XCTAssertTrue(html.contains("Binder name"))
            XCTAssertTrue(html.contains("e.g. 2026 Band Binder"))
            XCTAssertTrue(html.contains("id=\"yaml-output\""))
            // Nothing should be left unresolved by the partial extends.
            XCTAssertFalse(html.contains("#import("))
        }
    }

    func testBuilderPageRenders() async throws {
        try await app.test(.GET, "binder-builder") { res async in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            for id in self.sharedElementIDs {
                XCTAssertTrue(html.contains("id=\"\(id)\""), "missing #\(id)")
            }
            XCTAssertTrue(html.contains("/js/tune-selector.js"))
            XCTAssertTrue(html.contains("Your Binder"))
            XCTAssertTrue(html.contains("Your binder name"))
            XCTAssertTrue(html.contains("e.g. My 2026 Binder"))
            XCTAssertTrue(html.contains("id=\"download-section\""))
            XCTAssertFalse(html.contains("#import("))
        }
    }

    /// The shared styles partial has to reach both pages.
    func testBothPagesCarryTheSharedStyles() async throws {
        for path in ["binder-constructor", "binder-builder"] {
            try await app.test(.GET, path) { res async in
                XCTAssertTrue(res.body.string.contains(".part-tag.selected"), "\(path) lost the shared styles")
            }
        }
    }

    /// Sections are on for the personal builder (#29). The constructor keeps a
    /// flat selection until its YAML can carry sections (#21).
    func testOnlyTheBuilderTurnsSectionsOn() async throws {
        try await app.test(.GET, "binder-builder") { res async in
            XCTAssertTrue(res.body.string.contains("sections: true"))
            XCTAssertTrue(res.body.string.contains(".section-header"), "Section styles missing")
        }
        try await app.test(.GET, "binder-constructor") { res async in
            XCTAssertFalse(res.body.string.contains("sections: true"))
        }
    }

    /// A shared `spec` query parameter still reaches the page.
    func testBuilderPageEmbedsSharedSpec() async throws {
        let spec = Data(#"{"branch":"2026","name":"Test","entries":[]}"#.utf8).base64EncodedString()
        let encoded = spec.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? spec
        try await app.test(.GET, "binder-builder?spec=\(encoded)") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertTrue(res.body.string.contains(spec))
        }
    }
}
