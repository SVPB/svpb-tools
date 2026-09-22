import CeolKitSVGRenderer
import Foundation
import Logging
import SVGPDFKit
import XCTest
@testable import App

/// Covers the title page: that it holds to the same outlines contract as a tune
/// page, that its text lands where a title should, and that several lines stack
/// as a block rather than running together or off the page.
final class TitlePageRendererTests: XCTestCase {

    private let renderer = TitlePageRenderer()

    /// Letter, as `SVGRenderConfig(pageSize: .letter)` gives the tune pages.
    private let pageWidth = 612.0
    private let pageHeight = 792.0

    // MARK: - Helpers

    /// The `translate(x y)` of each line's group, in page order.
    private func lineOrigins(_ page: String) -> [(x: Double, y: Double)] {
        page.matches(of: /<g transform="translate\(([-0-9.]+) ([-0-9.]+)\)">/)
            .compactMap { match in
                guard let x = Double(match.1), let y = Double(match.2) else { return nil }
                return (x, y)
            }
    }

    /// The em size each line is set at, read back from the scale its glyph paths
    /// carry — `TextOutliner` scales an outline by `fontSize / unitsPerEm`, and
    /// Libertinus Serif is drawn on a 1000-unit em.
    private func lineFontSizes(_ page: String) -> [Double] {
        page.split(separator: "<g transform=\"translate(").dropFirst().compactMap { group in
            group.firstMatch(of: /scale\(([-0-9.]+)\s/).flatMap { Double($0.1).map { $0 * 1000 } }
        }
    }

    private func advanceWidth(_ text: String, fontSize: Double) throws -> Double {
        try TextOutliner.width(of: text, face: .libertinusSerifRegular, fontSize: fontSize)
    }

    // MARK: - Contract

    /// The same contract `ConversionPipelineTests` defends for tune pages: glyphs
    /// as self-contained geometry, never text resolved through a host font.
    func testTitleIsDrawnAsSelfContainedOutlines() throws {
        let page = try renderer.render(title: "Parade Set")

        XCTAssertTrue(page.hasPrefix("<svg"))
        XCTAssertTrue(page.hasSuffix("</svg>"))
        XCTAssertTrue(page.contains(#"viewBox="0 0 612.000 792.000""#), "Not a letter page")
        XCTAssertFalse(page.contains("@font-face"), "Title page carries an @font-face block")
        XCTAssertFalse(page.contains("<text"), "Title page paints <text> instead of outlines")
        // Nothing is referenced out of a <defs>: the fragment has to stand on its own.
        XCTAssertFalse(page.contains("<defs"), "Title page defines glyphs it then references")
        XCTAssertFalse(page.contains("<use"), "Title page references glyphs instead of drawing them")

        // One inked glyph per visible character; the space inks nothing.
        XCTAssertEqual(page.matches(of: /<path d="/).count, "ParadeSet".count)
    }

    /// Every glyph has to be one the face actually encodes, accents included:
    /// `.notdef` is drawn silently, so only its geometry gives it away.
    func testGlyphsDoNotFallBackToNotdef() throws {
        // A scalar no bundled face encodes, outlined to learn what `.notdef` looks like.
        let notdef = try TextOutliner.outline("\u{10FFFD}", face: .libertinusSerifRegular, fontSize: 45)
        let notdefPath = try XCTUnwrap(notdef.svg.firstMatch(of: /<path d="([^"]+)"/)?.1)

        let page = try renderer.render(title: "Sìne Bhàn")
        let paths = page.matches(of: /<path d="([^"]+)"/).map { String($0.1) }
        XCTAssertEqual(paths.count, "SìneBhàn".count)
        XCTAssertFalse(paths.contains(String(notdefPath)), "A glyph fell back to .notdef")
    }

    // MARK: - One line

    /// A one-line title sits centred, on the baseline a divider title has always
    /// used — 0.42 of the way down the page.
    func testSingleLineIsCentredOnTheDividerBaseline() throws {
        let page = try renderer.render(title: "Parade Set")

        let origins = lineOrigins(page)
        XCTAssertEqual(origins.count, 1)
        XCTAssertEqual(origins[0].y, pageHeight * 0.42, accuracy: 0.01)

        let size = try XCTUnwrap(lineFontSizes(page).first)  // Libertinus' unitsPerEm
        XCTAssertEqual(size, 45, accuracy: 0.1, "Short title was not set at the full size")
        let width = try advanceWidth("Parade Set", fontSize: size)
        XCTAssertEqual(origins[0].x, (pageWidth - width) / 2, accuracy: 0.01, "Title is not centred")
    }

    /// A long title shrinks to fit rather than running off the page.
    func testLongLineIsScaledToFitThePageWidth() throws {
        let title = String(repeating: "Strathspeys and Reels ", count: 6)
            .trimmingCharacters(in: .whitespaces)
        let page = try renderer.render(title: BinderTitle([title]))

        let size = try XCTUnwrap(lineFontSizes(page).first)
        XCTAssertLessThan(size, 45, "Long title was not reduced")

        let origin = try XCTUnwrap(lineOrigins(page).first)
        let width = try advanceWidth(title, fontSize: size)
        XCTAssertGreaterThan(origin.x, 0, "Long title runs off the left edge")
        XCTAssertLessThanOrEqual(width, pageWidth * 0.76 + 0.01, "Long title is wider than the page allows")
    }

    // MARK: - Several lines

    /// The case the issue opens with: a cover reading "SVPB Music" over "2027".
    func testMultiLineStacksAsABlock() throws {
        let page = try renderer.render(title: ["SVPB Music", "2027"])

        let origins = lineOrigins(page)
        XCTAssertEqual(origins.count, 2, "Two lines did not produce two groups")
        XCTAssertGreaterThan(origins[1].y, origins[0].y, "Second line is not below the first")

        // The block is centred on the baseline a single line would have used, so
        // adding a line grows the title in both directions rather than downwards.
        XCTAssertEqual((origins[0].y + origins[1].y) / 2, pageHeight * 0.42, accuracy: 0.01)

        let sizes = lineFontSizes(page)
        XCTAssertEqual(sizes.count, 2)
        XCTAssertLessThan(sizes[1], sizes[0], "The year is not set smaller than the title")
        XCTAssertEqual(origins[1].y - origins[0].y, sizes[1] * 1.35, accuracy: 0.01, "Wrong leading")

        for (line, index) in [("SVPB Music", 0), ("2027", 1)] {
            let width = try advanceWidth(line, fontSize: sizes[index])
            XCTAssertEqual(origins[index].x, (pageWidth - width) / 2, accuracy: 0.01,
                           "'\(line)' is not centred")
        }
    }

    /// Lines of wildly different lengths still share one size below the first, so
    /// the block does not read as three headings of three different ranks.
    func testLinesBelowTheFirstShareOneSizeAndAllFit() throws {
        let long = "for the Massed Bands at the Highland Games, Pleasanton"
        let page = try renderer.render(title: ["2027", long, "Grade 4"])

        let sizes = lineFontSizes(page)
        XCTAssertEqual(sizes.count, 3)
        XCTAssertEqual(sizes[1], sizes[2], accuracy: 0.001, "Lines below the first are set at different sizes")
        XCTAssertLessThan(sizes[1], sizes[0] * 0.62, "The long line did not shrink to fit")

        let origins = lineOrigins(page)
        // The size is read back through the rounding the SVG writes it with, so the
        // width it implies is the width it was fitted to give or take a fraction of a point.
        XCTAssertEqual(try advanceWidth(long, fontSize: sizes[1]), pageWidth * 0.76, accuracy: 0.05,
                       "The long line does not fill the width it was shrunk to")
        XCTAssertGreaterThan(origins[1].x, 0)
        XCTAssertEqual(Set(origins.map(\.y)).count, 3, "Two lines share a baseline")
    }

    // MARK: - Text handling

    /// Nothing goes through the ABC parser any more, so a title that looks like
    /// ABC is just text: one page, one line, no second tune (#46).
    func testTitleIsNoLongerEngravedThroughABC() throws {
        let page = try renderer.render(title: "Sìne Bhàn\nX:2\nT:Injected\nK:D\nABcd|")
        XCTAssertEqual(page.components(separatedBy: "</svg>").count - 1, 1)
        XCTAssertEqual(lineOrigins(page).count, 1, "The title broke into more than one line")
    }

    /// `%` and `\` had to be escaped while the title was an ABC field. They are
    /// ordinary characters now, and have to reach the page as themselves.
    func testPercentAndBackslashAreDrawnAsThemselves() throws {
        let notdef = try TextOutliner.outline("\u{10FFFD}", face: .libertinusSerifRegular, fontSize: 45)
        let notdefPath = try XCTUnwrap(notdef.svg.firstMatch(of: /<path d="([^"]+)"/)?.1)

        for title in ["100% Pipes", #"Back\slash"#, #"Ends in \% sign"#, #"trailing\"#] {
            let page = try renderer.render(title: BinderTitle([title]))
            let paths = page.matches(of: /<path d="([^"]+)"/).map { String($0.1) }
            let inked = title.replacing(" ", with: "").count
            XCTAssertEqual(paths.count, inked, "'\(title)' was truncated or padded")
            XCTAssertFalse(paths.contains(String(notdefPath)), "'\(title)' drew a .notdef")
        }
    }

    /// Whitespace within a line collapses, and a blank line is not a blank page.
    func testBlankLinesAreDropped() throws {
        let page = try renderer.render(title: ["  Massed   Bands ", "   ", "2027"])
        XCTAssertEqual(lineOrigins(page).count, 2, "The blank line took a line of its own")
        XCTAssertEqual(page.matches(of: /<path d="/).count, "MassedBands2027".count)
    }

    func testBlankTitleIsRejected() {
        XCTAssertThrowsError(try renderer.render(title: " \n\t "))
        XCTAssertThrowsError(try renderer.render(title: BinderTitle([])))
        XCTAssertThrowsError(try renderer.render(title: ["", "   "]))
    }

    // MARK: - Output

    func testTitlePageConvertsToPDF() throws {
        let pdf = try SVGPDFConverter(options: .engravedPages(logger: Logger(label: "test")))
            .makePDF(source: .string(renderer.render(title: ["Massed Bands", "2027"]))).pdfData
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
    }

    /// See `ConversionPipelineTests.testConvertedPDFDependsOnNoHostFont`: only the
    /// Linux rsvg-convert path can turn a title into host-resolved text.
    func testTitlePagePDFDependsOnNoHostFont() throws {
        #if canImport(CoreGraphics)
        throw XCTSkip("Not applicable on Apple platforms; CoreGraphics outlines every glyph regardless.")
        #else
        let pdf = try SVGPDFConverter(options: .engravedPages(logger: Logger(label: "test")))
            .makePDF(source: .string(renderer.render(title: ["Massed Bands", "2027"]))).pdfData
        let text = String(data: pdf, encoding: .isoLatin1) ?? ""
        let fonts = Set(text.matches(of: /\/BaseFont\s*\/(?:[A-Z]{6}\+)?([A-Za-z0-9\-]+)/).map { String($0.1) })
        XCTAssertTrue(fonts.isEmpty, "Title page PDF embeds fonts: \(fonts.sorted())")
        #endif
    }
}
