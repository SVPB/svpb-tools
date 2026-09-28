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
        "fold-all-sections", "add-title-page", "binder-pack",
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

    /// Both pages offer packing (#48), and each writes it into its own output: the
    /// constructor into `binders.yaml`, the builder into the spec it posts and shares.
    func testBothPagesOfferPacking() async throws {
        for path in ["binder-constructor", "binder-builder"] {
            try await app.test(.GET, path) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("Pack short tunes onto shared pages"),
                              "\(path) has no packing control")
                XCTAssertTrue(html.contains(".break-btn"),
                              "\(path) lost the per-entry break styles")
                XCTAssertTrue(html.contains("TuneSelector.packs()"),
                              "\(path) does not read the packing choice back out")
            }
        }
        try await app.test(.GET, "binder-constructor") { res async in
            // The file is written on the server now (#60), so what the page has
            // to carry is the choice and the per-entry opt-out, in the shape the
            // endpoint takes.
            XCTAssertTrue(res.body.string.contains("pack: b.pack"))
            XCTAssertTrue(res.body.string.contains("entry.break = 'before'"))
        }
        try await app.test(.GET, "binder-builder") { res async in
            XCTAssertTrue(res.body.string.contains("spec.pack = true"))
            XCTAssertTrue(res.body.string.contains("entry.break = 'before'"))
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

    /// A table of contents is a third kind of thing to add, beside a section and
    /// a title page (#47), and the header of a section that is one is marked as
    /// such and kept out of the list of places a tune can go.
    func testBothPagesOfferATableOfContents() async throws {
        for path in ["binder-constructor", "binder-builder"] {
            try await app.test(.GET, path) { res async in
                let html = res.body.string
                XCTAssertTrue(html.contains("id=\"add-toc\""), "\(path) has no table-of-contents control")
                XCTAssertTrue(html.contains(".section-header.contents"),
                              "\(path) lost the contents header styles")
                XCTAssertTrue(html.contains("TuneSelector.isContents"),
                              "\(path) does not write the contents section out")
            }
        }
        try await app.test(.GET, "js/tune-selector.js") { res async in
            let js = res.body.string
            XCTAssertTrue(js.contains("function addTableOfContents()"),
                          "the component cannot add a table of contents")
            XCTAssertTrue(js.contains("isContents(sections[targetIdx])"),
                          "a tune can still be moved into a table of contents")
        }
    }

    /// Both pages hand a contents section on; the builder writes the bare flag
    /// its spec has always carried, and the constructor passes the declaration
    /// through as it stands, so a `toc:` narrowed with `include:` survives a
    /// round trip (#60).
    func testEachPageWritesAContentsInItsOwnShape() async throws {
        try await app.test(.GET, "binder-constructor") { res async in
            XCTAssertTrue(res.body.string.contains("section.toc = s.toc"),
                          "the constructor cannot write a table of contents")
        }
        try await app.test(.GET, "binder-builder") { res async in
            XCTAssertTrue(res.body.string.contains("section.toc = true"),
                          "the builder cannot write a table of contents")
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

    /// The constructor sends the `binders.yaml` shape, not the personal spec.
    ///
    /// The YAML itself is written on the server (#60) — so the page's job is to
    /// map `tuneSlug` back to `tune` at the edge and post the result, and what
    /// is asserted here is that mapping and the two endpoints it uses.
    func testConstructorEmitsBindersYAMLShape() async throws {
        try await app.test(.GET, "binder-constructor") { res async in
            let html = res.body.string
            XCTAssertTrue(html.contains("id=\"binder-output\""))
            XCTAssertTrue(html.contains("{ tune: e.tuneSlug }"))
            // A multi-line title is written as a YAML list, a one-line one as a string.
            XCTAssertTrue(html.contains("title.length > 1"), "the constructor cannot write a multi-line title")
            XCTAssertFalse(html.contains("tune_slug"))
            XCTAssertTrue(html.contains("/binder-constructor/yaml"))
            XCTAssertTrue(html.contains("/binder-constructor/check"))
            // String concatenation in the browser is what #60 removed; nothing
            // in the test suite could execute it.
            XCTAssertFalse(html.contains("'binders:'"), "the page is building the file by hand again")
        }
    }

    /// The constructor holds the whole file, not one binder (#60): a picker over
    /// every binder it declares, controls to add and remove one, and a Load
    /// button that reads a pasted file back in.
    func testConstructorHoldsTheWholeFile() async throws {
        try await app.test(.GET, "binder-constructor") { res async in
            let html = res.body.string
            for id in ["binder-picker", "add-binder", "remove-binder"] {
                XCTAssertTrue(html.contains("id=\"\(id)\""), "missing #\(id)")
            }
            XCTAssertTrue(html.contains("loadYAML()"), "the page cannot load a file back in")
            XCTAssertTrue(html.contains("function fileBinders()"),
                          "the page does not send every binder it holds")
            // The copy instruction is the largest hazard in the feature: a file
            // appended to an existing one declares every binder twice.
            XCTAssertTrue(html.contains("Copy it over"), "the page still says to append its output")
            XCTAssertFalse(html.contains("at the end of that file"))
        }
        // The builder composes one binder and has none of this.
        try await app.test(.GET, "binder-builder") { res async in
            XCTAssertFalse(res.body.string.contains("id=\"binder-picker\""))
        }
    }

    /// The two rules that differ between the pages (#60). The builder keeps the
    /// behaviour it had: one tune once, and a tune this year lacks quietly dropped.
    func testOnlyTheConstructorRepeatsTunesAndKeepsUnknownOnes() async throws {
        try await app.test(.GET, "binder-constructor") { res async in
            let html = res.body.string
            XCTAssertTrue(html.contains("repeatableTunes: true"))
            XCTAssertTrue(html.contains("keepUnknownTunes: true"))
            XCTAssertTrue(html.contains(".missing-flag"), "an unresolved entry is not marked")
        }
        try await app.test(.GET, "binder-builder") { res async in
            let html = res.body.string
            XCTAssertFalse(html.contains("repeatableTunes"))
            XCTAssertFalse(html.contains("keepUnknownTunes"))
        }
        try await app.test(.GET, "js/tune-selector.js") { res async in
            let js = res.body.string
            XCTAssertTrue(js.contains("function setSections(list)"),
                          "a page holding several binders cannot switch between them")
            XCTAssertTrue(js.contains("Added ×"), "the catalogue cannot say a tune is in twice")
            XCTAssertTrue(js.contains("declaredParts"),
                          "a declared parts list is not carried through the component")
            // The trap: /tunes/:slug 404s on a slug the branch does not have, and
            // one unresolved entry would abandon the whole load.
            XCTAssertTrue(js.contains("const parts = tune ? (await getTuneDetail(e.tuneSlug)).parts.map(p => p.name) : [];"),
                          "the component asks for the detail of a tune it knows is missing")
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
