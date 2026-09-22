import CeolKitParser
import CeolKitSVGRenderer
import Foundation
import Logging
import SVGPDFKit
import XCTest
@testable import App

/// #62: a page is bound at the size it was engraved.
///
/// The 2027 binder went to Box with every landscape tune printed at 68% and five blank
/// inches at the foot of the sheet. Nothing was wrong with the engraving: the converter
/// was handed one portrait page size for a document whose tunes choose their own
/// orientation, and 65 of the 84 tunes chose landscape.
///
/// So what is defended here is the chain that produced that page, in the order the pages
/// pass through it — what CeolKit engraves, what the front matter this server draws says
/// about itself, and what the converter does with both.
///
/// With `pageSize` nil the media box *is* the page the document declares, so the page each
/// SVG states and the absence of a `pageSizeMismatch` diagnostic are the contract, and both
/// are checked on either backend. Reading the media boxes back out of the PDF confirms it
/// end to end, and is possible only where the file writes its page dictionaries in plain
/// bytes — see `pdfPageSizesOrSkip`.
final class EngravedPageSizeTests: XCTestCase {

    // MARK: - What CeolKit engraves

    /// `%%landscape` is the tune's to set, and the band's tunes mostly set it. A renderer
    /// configured for letter still turns the page where the source says to.
    func testEachTuneIsEngravedInItsOwnOrientation() throws {
        XCTAssertEqual(declaredPageSize(ofSVG: try engrave(landscape: true)),
                       PDFPageSize(width: 792, height: 612))
        XCTAssertEqual(declaredPageSize(ofSVG: try engrave(landscape: false)),
                       PDFPageSize(width: 612, height: 792))
    }

    /// The units on the root `<svg>` are load-bearing, because the conversion reads the
    /// page off the document: a unitless 612 is 612 CSS pixels, which is 459 points, so a
    /// page that does not say `pt` is bound at three quarters of its size. (That is also
    /// why `declaredPageSize(ofSVG:)` above reads `pt` and nothing else.)
    func testAnEngravedPageStatesItsSizeInPoints() throws {
        let page = try engrave(landscape: true)
        XCTAssertTrue(page.contains(#"width="792pt""#) && page.contains(#"height="612pt""#),
                      "CeolKit's root <svg> no longer states the page in points: "
                      + "\(page.prefix(200))")
    }

    // MARK: - What the converter does with it

    /// The fix. Two tunes that disagree about orientation convert as one document with
    /// nothing scaled to fit the other's page — which the converter reports on, or rather
    /// does not.
    func testMixedOrientationsAreNotScaledToFitOneAnother() throws {
        let result = try convert(try engraved(landscape: [true, false]), options: options())

        XCTAssertEqual(result.diagnostics.map(\.description), [],
                       "A page bound at the size it was engraved has nothing to report")
    }

    /// And the bug, so that a return to the defaults cannot pass as working. One page size
    /// for the whole document is a guess, and it was wrong for three quarters of the 2027
    /// binder: the landscape page is fitted onto a portrait one, at 68%.
    func testOnePageSizeForTheWholeDocumentShrinksTheMusic() throws {
        var defaults = ConversionOptions()
        defaults.injectPageNumbers = false
        defaults.diagnosticHandler = .silent

        let result = try convert(try engraved(landscape: [true, false]), options: defaults)

        let scales = result.diagnostics.compactMap { diagnostic -> Double? in
            guard case .pageSizeMismatch(_, _, let scale) = diagnostic.kind else { return nil }
            return scale
        }
        XCTAssertEqual(scales.first ?? 0, 540.0 / 792, accuracy: 0.001,
                       "68% is the shrink #62 measured on 48 of the binder's 65 pages")
    }

    /// The options themselves, since both settings exist to *not* do something and a
    /// plausible-looking default would put either back.
    func testEngravedPagesTakesThePageFromTheDocument() {
        let options = options()
        XCTAssertNil(options.pageSize,
                     "A page size named here is a guess about tunes this code has not read")
        XCTAssertFalse(options.injectPageNumbers,
                       "CeolKit numbers its own pages in outlines; there is no placeholder to fill")
    }

    /// End to end, on the backend whose PDFs can be read: the media box of each page is the
    /// page its own SVG declared, in the order they went in.
    func testBoundMediaBoxesAreTheEngravedPages() throws {
        let result = try convert(try engraved(landscape: [true, false]), options: options())

        // Hoisted out of the assertion: a skip thrown inside an XCTAssert autoclosure is
        // reported as an unexpected error rather than a skip.
        let sizes = try pdfPageSizesOrSkip(result.pdfData)
        XCTAssertEqual(sizes, [PDFPageSize(width: 792, height: 612),
                               PDFPageSize(width: 612, height: 792)])
    }

    // MARK: - Front matter

    /// A title page and a contents page are drawn here rather than by CeolKit, and they go
    /// into the same PDF, so they have to declare their page the same way. Portrait letter
    /// either way — a binder's mixed page sizes are the tunes', not the front matter's.
    func testFrontMatterIsBoundAsPortraitLetter() throws {
        for (what, svg) in try frontMatter() {
            XCTAssertTrue(svg.contains(#"width="612.000pt""#),
                          "The \(what) does not state its page in points, so it is bound at 75%")
            XCTAssertEqual(declaredPageSize(ofSVG: svg),
                           PDFPageSize(width: 612, height: 792), "\(what)")
        }

        let result = try convert(try frontMatter().map(\.svg), options: options())
        XCTAssertEqual(result.diagnostics.map(\.description), [])
        let sizes = try pdfPageSizesOrSkip(result.pdfData)
        XCTAssertEqual(sizes, [PDFPageSize(width: 612, height: 792),
                               PDFPageSize(width: 612, height: 792)])
    }

    // MARK: - Helpers

    private func options() -> ConversionOptions {
        .engravedPages(logger: Logger(label: "EngravedPageSizeTests"))
    }

    private func convert(_ pages: [String], options: ConversionOptions) throws -> ConversionResult {
        try SVGPDFConverter(options: options).makePDF(sources: pages.map { .string($0) })
    }

    /// A title page and a contents page, labelled for failure output.
    private func frontMatter() throws -> [(what: String, svg: String)] {
        let title = try TitlePageRenderer().render(title: ["Massed Bands", "2027"])
        let contents = try XCTUnwrap(
            TableOfContentsRenderer().render(
                heading: "Contents",
                entries: [.init(text: "Scotland the Brave", level: 0, page: 2)],
                pageCount: 1
            ).first?.svg
        )
        return [("title page", title), ("contents page", contents)]
    }

    /// One page of engraved music, in the orientation the source asks for.
    private func engrave(landscape: Bool) throws -> String {
        let abc = """
        %abc-2.2
        %%landscape \(landscape ? 1 : 0)
        %%footer "$P"
        X:1
        T:\(landscape ? "Wide March" : "Tall March")
        M:4/4
        L:1/8
        K:D
        ABcd efga | gfed cBAG | ABcd efga | g2 f2 e2 d2 |]
        """
        let parsed = CeolKitParser().parse(abc, options: .default)
        let pages = try SVGRenderer(config: .init(pageSize: .letter)).render(parsed.score)
        XCTAssertEqual(pages.count, 1, "The fixture is one page of music")
        return try XCTUnwrap(pages.first)
    }

    private func engraved(landscape: [Bool]) throws -> [String] {
        try landscape.map { try engrave(landscape: $0) }
    }
}
