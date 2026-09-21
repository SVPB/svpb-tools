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
        "fold-all-sections", "add-title-page",
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
                XCTAssertTrue(res.body.string.contains(".binder-entries .section-header.active"),
                              "\(path) lost the shared styles")
            }
        }
    }

    /// Both pages have sections (#29, #21). Only the constructor needs every
    /// section titled, since `binders.yaml` has no untitled sections.
    func testSectionOptionsPerPage() async throws {
        try await app.test(.GET, "binder-builder") { res async in
            let html = res.body.string
            XCTAssertTrue(html.contains("sections: true"))
            XCTAssertTrue(html.contains(".section-header"), "Section styles missing")
            XCTAssertFalse(html.contains("untitledSections: false"))
        }
        try await app.test(.GET, "binder-constructor") { res async in
            let html = res.body.string
            XCTAssertTrue(html.contains("sections: true"))
            XCTAssertTrue(html.contains("untitledSections: false"))
        }
    }

    /// A section can be folded down to its header row (#45), so both pages need
    /// the grouping markup's styles as well as the fold-everything control.
    func testBothPagesCanFoldSections() async throws {
        for path in ["binder-constructor", "binder-builder"] {
            try await app.test(.GET, path) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains(".section-group"), "\(path) lost the section grouping styles")
                XCTAssertTrue(html.contains(".section-tunes"), "\(path) lost the folded-list styles")
                XCTAssertTrue(html.contains(".fold-btn"), "\(path) lost the disclosure styles")
            }
        }
    }
  
    /// A title page is a first-class thing to add, beside "add section" (#46),
    /// and the header of a section that is one is marked as such.
    func testBothPagesOfferATitlePage() async throws {
        for path in ["binder-constructor", "binder-builder"] {
            try await app.test(.GET, path) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("id=\"add-title-page\""), "\(path) has no title-page control")
                XCTAssertTrue(html.contains(".section-header.title-page"),
                              "\(path) lost the title-page header styles")
                XCTAssertTrue(html.contains("textarea.section-title"),
                              "\(path) still styles the title as a single-line input")
            }
        }
        try await app.test(.GET, "js/tune-selector.js") { res async in
            let js = res.body.string
            XCTAssertTrue(js.contains("function addTitlePage()"), "the component cannot add a title page")
            XCTAssertTrue(js.contains("createElement('textarea')"),
                          "the component still edits a title on one line")
        }
    }

    /// Neither page offers a part to choose (#24): every part of a tune is the
    /// same multi-voice score until #20, so the tags could only mislead — and
    /// the builder's default of "all parts selected" put the score in the
    /// binder once per voice.
    func testNoPageOffersPartSelection() async throws {
        for path in ["binder-constructor", "binder-builder"] {
            try await app.test(.GET, path) { res async in
                XCTAssertFalse(res.body.string.contains("part-tag"), "\(path) still styles part tags")
            }
        }
        try await app.test(.GET, "js/tune-selector.js") { res async in
            XCTAssertEqual(res.status, .ok)
            let js = res.body.string
            XCTAssertFalse(js.contains("togglePart"), "the component still toggles parts")
            XCTAssertFalse(js.contains("part-tag"), "the component still renders part tags")
        }
    }

    /// The constructor writes the `binders.yaml` shape, not the personal spec.
    func testConstructorEmitsBindersYAMLShape() async throws {
        try await app.test(.GET, "binder-constructor") { res async in
            let html = res.body.string
            XCTAssertTrue(html.contains("id=\"binder-output\""))
            XCTAssertTrue(html.contains("'binders:'"))
            XCTAssertTrue(html.contains("- tune: "))
            // A multi-line title is written as a YAML list, a one-line one as a string.
            XCTAssertTrue(html.contains("title.length > 1"), "the constructor cannot write a multi-line title")
            XCTAssertFalse(html.contains("tune_slug"))
            XCTAssertFalse(html.contains("parts:`"), "the constructor must not emit parts")
            XCTAssertTrue(html.contains("/binder-constructor/check"))
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
