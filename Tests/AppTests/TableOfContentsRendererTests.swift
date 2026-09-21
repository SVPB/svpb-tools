import CeolKitSVGRenderer
import Foundation
import SVGPDFKit
import XCTest
@testable import App

/// Covers the contents page: that it holds to the same outlines contract as a
/// tune page, that a line reads name-leader-number across the measure, that the
/// numbers right-align however many digits they carry, and that a listing too
/// long for one page runs onto the next without losing a line (#47).
final class TableOfContentsRendererTests: XCTestCase {

    private let renderer = TableOfContentsRenderer()

    /// Letter, as `SVGRenderConfig(pageSize: .letter)` gives the tune pages.
    private let pageWidth = 612.0
    private let pageHeight = 792.0
    private let margin = 72.0

    // MARK: - Helpers

    private func entry(_ text: String, level: Int = 0, page: Int) -> TableOfContentsRenderer.Entry {
        TableOfContentsRenderer.Entry(text: text, level: level, page: page)
    }

    /// One positioned run of glyphs: where its pen origin sits, and how many
    /// glyphs it inked.
    private struct Run {
        let x: Double
        let y: Double
        let glyphs: Int
    }

    /// Every run on a page, in document order.
    private func runs(_ page: String) -> [Run] {
        page.split(separator: "<g transform=\"translate(").dropFirst().compactMap { group in
            guard let origin = group.firstMatch(of: /^([-0-9.]+) ([-0-9.]+)\)">/),
                  let x = Double(origin.1), let y = Double(origin.2) else { return nil }
            return Run(x: x, y: y, glyphs: group.matches(of: /<path d="/).count)
        }
    }

    /// The runs sharing a baseline, in document order: a line's name, its
    /// leader, and its number.
    private func line(_ page: String, at baseline: Double) -> [Run] {
        runs(page).filter { abs($0.y - baseline) < 0.001 }
    }

    private func width(_ text: String, fontSize: Double = 12) throws -> Double {
        try TextOutliner.width(of: text, face: .libertinusSerifRegular, fontSize: fontSize)
    }

    /// The baseline of the `index`th entry on the first page, which carries the
    /// heading and so starts lower than the pages after it.
    private let firstEntryBaseline = 126.0
    private let lineHeight = 18.0
    private func baseline(_ index: Int) -> Double { firstEntryBaseline + Double(index) * lineHeight }

    private func render(_ entries: [TableOfContentsRenderer.Entry],
                        heading: String = TableOfContentsRenderer.defaultHeading,
                        pageCount: Int? = nil) throws -> [TableOfContentsRenderer.Page] {
        try renderer.render(heading: heading, entries: entries,
                            pageCount: pageCount ?? renderer.pageCount(forEntries: entries.count))
    }

    // MARK: - Contract

    /// The same contract `ConversionPipelineTests` defends for tune pages, and
    /// `TitlePageRendererTests` for title pages: glyphs as self-contained
    /// geometry, never text resolved through a host font.
    func testContentsIsDrawnAsSelfContainedOutlines() throws {
        let page = try render([entry("Parade Set", page: 2)])[0].svg

        XCTAssertTrue(page.hasPrefix("<svg"))
        XCTAssertTrue(page.hasSuffix("</svg>"))
        XCTAssertTrue(page.contains(#"viewBox="0 0 612.000 792.000""#), "Not a letter page")
        XCTAssertTrue(page.contains(#"class="table-of-contents""#))
        XCTAssertFalse(page.contains("@font-face"), "Contents page carries an @font-face block")
        XCTAssertFalse(page.contains("<text"), "Contents page paints <text> instead of outlines")
        XCTAssertFalse(page.contains("<defs"), "Contents page defines glyphs it then references")
        XCTAssertFalse(page.contains("<use"), "Contents page references glyphs instead of drawing them")
    }

    /// `.notdef` is drawn as an empty path, so a glyph the face does not encode
    /// would silently vanish — including the ellipsis a shortened name ends in.
    func testEveryGlyphOfALineIsInked() throws {
        let page = try render([entry("Sìne Bhàn", page: 12)])[0].svg
        let drawn = line(page, at: baseline(0))
        XCTAssertEqual(drawn.count, 3, "A line is a name, a leader, and a number")
        XCTAssertEqual(drawn[0].glyphs, "SìneBhàn".count, "The name lost a glyph")
        XCTAssertEqual(drawn[2].glyphs, 2, "The number lost a digit")

        let shortened = try renderer.shortened("Mist Covered Mountains", toFit: 40)
        XCTAssertTrue(shortened.hasSuffix("…"))
        let outlined = try TextOutliner.outline(shortened, face: .libertinusSerifRegular, fontSize: 12)
        XCTAssertEqual(outlined.svg.matches(of: /<path d="/).count,
                       shortened.filter { !$0.isWhitespace }.count,
                       "The ellipsis is not inked by this face")
    }

    // MARK: - A line

    /// Name flush left on the margin, number flush right on it, and a leader
    /// that touches neither.
    func testALineReadsNameLeaderNumberAcrossTheMeasure() throws {
        let page = try render([entry("G4 Tunes", page: 2)])[0].svg
        let drawn = line(page, at: baseline(0))
        XCTAssertEqual(drawn.count, 3)

        let (name, leader, number) = (drawn[0], drawn[1], drawn[2])
        XCTAssertEqual(name.x, margin, accuracy: 0.001, "The name is not flush left")
        XCTAssertEqual(number.x + (try width("2")), pageWidth - margin, accuracy: 0.01,
                       "The number is not flush right")

        let nameEnd = name.x + (try width("G4 Tunes"))
        XCTAssertGreaterThan(leader.x, nameEnd, "The leader runs into the name")
        XCTAssertGreaterThan(drawn[1].glyphs, 10, "The leader is barely a leader")
        let leaderEnd = leader.x + (try width(Array(repeating: ".", count: leader.glyphs).joined(separator: " ")))
        XCTAssertLessThan(leaderEnd, number.x, "The leader runs into the number")
    }

    /// The whole point of a column of numbers: 9, 13 and 117 end on one margin,
    /// so they read down the page as a column rather than as a ragged edge.
    func testNumbersRightAlignHoweverManyDigits() throws {
        let page = try render([
            entry("One", page: 9),
            entry("Two", page: 13),
            entry("Three", page: 117),
        ])[0].svg

        for (index, number) in ["9", "13", "117"].enumerated() {
            let drawn = line(page, at: baseline(index))
            XCTAssertEqual(drawn.count, 3, "Line \(index + 1) is not name, leader, number")
            XCTAssertEqual(drawn[2].x + (try width(number)), pageWidth - margin, accuracy: 0.01,
                           "Page \(number) does not end on the right margin")
        }
    }

    /// Tunes sit one step in from the section they belong to; a listing with no
    /// sections in it sets them flush left instead.
    func testTunesAreIndentedUnderTheirSection() throws {
        let page = try render([
            entry("G4 Tunes", level: 0, page: 2),
            entry("Scotland the Brave", level: 1, page: 3),
        ])[0].svg

        XCTAssertEqual(line(page, at: baseline(0))[0].x, margin, accuracy: 0.001)
        XCTAssertEqual(line(page, at: baseline(1))[0].x, margin + 18, accuracy: 0.001)
    }

    /// A name with no room for its own line is cut and marked as cut, rather
    /// than set smaller than its neighbours or wrapped onto a line whose number
    /// would then belong to neither half.
    func testATooLongNameIsShortenedWithAnEllipsis() throws {
        let long = String(repeating: "Cabar Feidh gu Brath ", count: 12)
        let page = try render([entry(long, page: 7)])[0].svg
        let drawn = line(page, at: baseline(0))

        // The number keeps its margin: it is the name that gives way.
        let numberX = pageWidth - margin - (try width("7"))
        XCTAssertEqual(drawn.last?.x ?? 0, numberX, accuracy: 0.01,
                       "The number moved off the right margin to make room")

        // The name fits what is left of the measure, less the separation the
        // renderer always keeps between a name and its number.
        let available = numberX - 12 - margin
        let shortened = try renderer.shortened(long, toFit: available)
        XCTAssertTrue(shortened.hasSuffix("…"), "A cut name does not say it was cut")
        XCTAssertLessThan(shortened.count, long.count)
        XCTAssertLessThanOrEqual(try width(shortened), available)
        XCTAssertEqual(drawn[0].glyphs, shortened.filter { !$0.isWhitespace }.count,
                       "The page drew something other than the shortened name")
    }

    // MARK: - Pagination

    /// The first page holds fewer lines, because the heading is on it. Both
    /// counts have to be a property of the layout rather than of the text, since
    /// `BinderService` reserves the pages before there is anything to draw.
    func testTheFirstPageHoldsFewerLinesThanTheRest() {
        XCTAssertGreaterThan(renderer.linesOnFirstPage, 0)
        XCTAssertGreaterThan(renderer.linesOnLaterPages, renderer.linesOnFirstPage)
        XCTAssertEqual(renderer.pageCount(forEntries: 0), 1, "A binder that asks for contents gets a page")
        XCTAssertEqual(renderer.pageCount(forEntries: renderer.linesOnFirstPage), 1)
        XCTAssertEqual(renderer.pageCount(forEntries: renderer.linesOnFirstPage + 1), 2)
        XCTAssertEqual(
            renderer.pageCount(forEntries: renderer.linesOnFirstPage + renderer.linesOnLaterPages), 2)
        XCTAssertEqual(
            renderer.pageCount(forEntries: renderer.linesOnFirstPage + renderer.linesOnLaterPages + 1), 3)
    }

    /// A listing longer than one page spills in order, keeps every line, and
    /// heads only its first page.
    func testALongListingSpillsOntoFurtherPagesInOrder() throws {
        let count = renderer.linesOnFirstPage + 5
        let entries = (1 ... count).map { entry("Tune \($0)", page: $0) }
        let pages = try render(entries)

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].entries.count, renderer.linesOnFirstPage)
        XCTAssertEqual(pages[1].entries.count, 5)
        XCTAssertEqual(pages.flatMap(\.entries), entries, "A line was lost or reordered in the spill")

        // The heading is on the first page only, and the second starts higher up
        // because of it.
        let headingWidth = try width(TableOfContentsRenderer.defaultHeading, fontSize: 24)
        XCTAssertEqual(runs(pages[0].svg).first?.y, margin + 24)
        XCTAssertEqual(runs(pages[0].svg).first?.glyphs, "Contents".count)
        XCTAssertGreaterThan(headingWidth, 0)
        XCTAssertEqual(runs(pages[1].svg).first?.y, margin + 12, "The second page left room for a heading it has not got")
    }

    /// The caller reserved the pages before the listing was drawn, so it gets
    /// back exactly what it reserved — even when the listing has since shrunk.
    func testExactlyTheReservedPagesComeBack() throws {
        let pages = try render([entry("One", page: 4)], pageCount: 3)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages[0].entries.count, 1)
        XCTAssertTrue(pages[1].entries.isEmpty)
        XCTAssertTrue(pages[2].entries.isEmpty)
        for page in pages {
            XCTAssertTrue(page.svg.hasPrefix("<svg"))
            XCTAssertTrue(page.svg.contains(#"viewBox="0 0 612.000 792.000""#))
        }
    }

    /// A blank page still has to be a page: the slot was counted into every
    /// number after it.
    func testABlankPageIsStillALetterPage() {
        let blank = renderer.blankPage()
        XCTAssertTrue(blank.entries.isEmpty)
        XCTAssertTrue(blank.svg.contains(#"viewBox="0 0 612.000 792.000""#))
        XCTAssertFalse(blank.svg.contains("<path"))
    }

    // MARK: - Conversion

    /// The page has to survive the same pipeline the tune pages go through.
    func testContentsPageConvertsToPDF() throws {
        let pages = try render([
            entry("G4 Tunes", page: 2),
            entry("Scotland the Brave", level: 1, page: 3),
        ])
        var options = ConversionOptions()
        options.injectPageNumbers = false
        let pdf = try SVGPDFConverter(options: options).convert(sources: pages.map { .string($0.svg) })
        XCTAssertTrue(pdf.starts(with: Array("%PDF".utf8)))
        XCTAssertGreaterThan(pdf.count, 1000)
    }
}
