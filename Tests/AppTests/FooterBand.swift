import CeolKitSVGGeometry
import CeolKitSVGRenderer
import XCTest

/// The strip at the foot of an engraved page that a `%%footer` prints in, and the check that
/// no system reaches into it (#71).
///
/// CeolKit stamps the footer on after layout, with its descenders on the bottom margin and its
/// ascenders ~14 pt above it. Until sbeitzel/CeolKit#192 the layout only kept systems above the
/// bare margin, so the last system on a full page could print straight through the footer.
///
/// This is checked on geometry rather than on pixels: `SVGGeometry` reads each system's staff
/// back out of the emitted SVG, and the band's top is known from CeolKit's own constants. No
/// rasteriser and no `qpdf`, so it runs the same on macOS and on Linux CI.
enum FooterBand {

    /// CeolKit's footer text size, in points. Absolute: `%%ceolkit:scale` does not reach it
    /// (sbeitzel/CeolKit#203). CeolKit keeps the constant internal, so it is restated here.
    static let fontSize = 12.0

    /// The bottom margin both renderers engrave with — they leave it at its default.
    static let bottomMargin = SVGRenderConfig(pageSize: .letter).margins.bottom

    /// The y of the top of the footer's ascenders on a page of height `pageHeight`. A staff
    /// whose bottom line is below this prints over the footer.
    static func top(pageHeight: Double) -> Double {
        pageHeight - bottomMargin
            - fontSize * (LibertinusSerifMetrics.ascenderRatio + LibertinusSerifMetrics.descenderRatio)
    }

    /// Every system, on every page, whose bottom staff line reaches into the footer band —
    /// as `(page index, bottomY, band top)`, for a failure message worth reading.
    static func intrusions(in pages: [String]) throws -> [(page: Int, bottomY: Double, top: Double)] {
        try SVGGeometry.pages(from: pages).enumerated().flatMap { index, page in
            let top = top(pageHeight: page.height)
            return page.systems.filter { $0.bottomY > top }.map { (index, $0.bottomY, top) }
        }
    }
}

/// Fails if any system on any of `pages` prints into the footer band.
func assertClearOfFooter(_ pages: [String], file: StaticString = #filePath, line: UInt = #line) throws {
    let intrusions = try FooterBand.intrusions(in: pages)
    XCTAssertTrue(intrusions.isEmpty, "systems print over the footer: \(intrusions)", file: file, line: line)
}
