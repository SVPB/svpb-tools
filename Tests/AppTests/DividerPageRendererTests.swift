import CeolKitParser
import Foundation
import SVGPDFKit
import XCTest
@testable import App

/// Covers the section divider page: that it holds to the same outlines contract
/// as a tune page, that the title lands where a divider title should, and that
/// no title can break out of the ABC it is engraved through.
final class DividerPageRendererTests: XCTestCase {

    private let renderer = DividerPageRenderer()

    /// The same contract `ConversionPipelineTests` defends for tune pages: glyphs
    /// as self-contained geometry, never text resolved through a host font.
    func testDividerIsDrawnAsSelfContainedOutlines() throws {
        let page = try renderer.render(title: "Parade Set")

        XCTAssertTrue(page.contains("<svg"))
        XCTAssertTrue(page.hasSuffix("</svg>"))
        XCTAssertFalse(page.contains("@font-face"), "Divider carries an @font-face block")
        XCTAssertFalse(page.contains("<text"), "Divider paints <text> instead of outlines")

        let defined = Set(page.matches(of: /<path id="([A-Za-z]+-g\d+)" d="[^"]+"/).map { String($0.1) })
        let drawn = page.matches(of: /<use href="#([^"]+)"/).map { String($0.1) }
        XCTAssertEqual(drawn.count, "ParadeSet".count, "One glyph per visible character")
        XCTAssertTrue(Set(drawn).isSubset(of: defined),
                      "Undefined outlines: \(Set(drawn).subtracting(defined).sorted())")
        XCTAssertFalse(drawn.contains { $0.hasSuffix("-g0") }, "A glyph fell back to .notdef")
    }

    /// CeolKit puts a title across the top of the page; a divider wants it large
    /// and in the upper-middle. Every glyph has to be inside the moved group.
    func testTitleIsMovedDownThePageAndEnlarged() throws {
        let page = try renderer.render(title: "Parade Set")

        let group = try XCTUnwrap(
            page.firstMatch(of: /<g class="divider-title" transform="translate\(([-0-9.]+) ([-0-9.]+)\) scale\(([-0-9.]+)\)/),
            "No divider-title group"
        )
        XCTAssertEqual(Double(group.1)!, 306, accuracy: 0.01, "Not scaled about the centre line")
        XCTAssertGreaterThan(Double(group.2)!, 792 * 0.3, "Title still near the top of the page")
        XCTAssertGreaterThan(Double(group.3)!, 1.5, "Short title was not enlarged")

        let body = try XCTUnwrap(page.split(separator: "divider-title").last)
        XCTAssertEqual(body.matches(of: /<use\s/).count, "ParadeSet".count, "Glyphs left outside the group")
    }

    /// A long title shrinks to fit rather than running off the page.
    func testLongTitleIsScaledToFitThePageWidth() throws {
        let title = String(repeating: "Strathspeys and Reels ", count: 6)
        let page = try renderer.render(title: title)

        let group = try XCTUnwrap(page.firstMatch(of: /scale\(([-0-9.]+)\) translate\(([-0-9.]+)\s/))
        let scale = Double(group.1)!
        let lefts = page.matches(of: /<use\b[^>]*transform="translate\(([-0-9.]+)\s/).compactMap { Double($0.1) }
        let left = try XCTUnwrap(lefts.min())

        // Scaled about x = 306, the first glyph's position on the finished page.
        let scaledLeft = 306 + (left - 306) * scale
        XCTAssertGreaterThan(scaledLeft, 0, "Long title runs off the left edge")
        XCTAssertLessThan(scale, 1, "Long title was not reduced")
    }

    /// A line break would end the `T:` field and let the rest of the title be
    /// read as ABC — here, a second tune and a second page.
    func testLineBreaksCannotInjectABC() throws {
        let page = try renderer.render(title: "Sìne Bhàn\nX:2\nT:Injected\nK:D\nABcd|")
        XCTAssertEqual(page.components(separatedBy: "</svg>").count - 1, 1)
        XCTAssertEqual(DividerPageRenderer.abcSafe("Sìne Bhàn\nX:2\r\n\tT:x"), "Sìne Bhàn X:2 T:x")
    }

    /// CeolKit ends a field at `%` whatever precedes it (sbeitzel/CeolKit#145).
    func testPercentSignSurvivesAsAWord() throws {
        XCTAssertEqual(DividerPageRenderer.abcSafe("100% Pipes"), "100 percent Pipes")

        let page = try renderer.render(title: "100% Pipes")
        XCTAssertEqual(page.matches(of: /<use\s/).count, "100percentPipes".count, "Title was truncated at the %")
    }

    /// Canary for sbeitzel/CeolKit#145. `abcSafe` spells `%` out only because
    /// CeolKit ignores the standard's `\%` escape and ends the field anyway. When
    /// this fails, CeolKit has started honouring the escape: change `abcSafe` to
    /// escape `%` as `\%` (and `\` as `\\`, if that is decoded too), update
    /// `testPercentSignSurvivesAsAWord`, raise the CeolKit minimum in
    /// `Package.swift`, and delete this test.
    func testCeolKitStillIgnoresTheEscapedPercent() {
        let parsed = CeolKitParser().parse("X:1\nT:100\\% Pipes\nK:none\n", options: .default)
        XCTAssertEqual(
            parsed.score.tunes.first?.titles.first?.value, "100\\",
            "CeolKit now handles \\% (sbeitzel/CeolKit#145). Replace the percent workaround "
            + "in DividerPageRenderer.abcSafe with a real escape."
        )
    }

    func testBlankTitleIsRejected() {
        XCTAssertThrowsError(try renderer.render(title: " \n\t "))
    }

    func testDividerConvertsToPDF() throws {
        let pdf = try SVGPDFConverter().convert(source: .string(renderer.render(title: "Massed Bands")))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
    }

    /// See `ConversionPipelineTests.testConvertedPDFDependsOnNoHostFont`: only the
    /// Linux rsvg-convert path can turn a divider title into host-resolved text.
    func testDividerPDFDependsOnNoHostFont() throws {
        #if canImport(CoreGraphics)
        throw XCTSkip("Not applicable on Apple platforms; CoreGraphics outlines every glyph regardless.")
        #else
        let pdf = try SVGPDFConverter().convert(source: .string(renderer.render(title: "Massed Bands")))
        let text = String(data: pdf, encoding: .isoLatin1) ?? ""
        let fonts = Set(text.matches(of: /\/BaseFont\s*\/(?:[A-Z]{6}\+)?([A-Za-z0-9\-]+)/).map { String($0.1) })
        XCTAssertTrue(fonts.isEmpty, "Divider PDF embeds fonts: \(fonts.sorted())")
        #endif
    }
}
