import CeolKitParser
import CeolKitSVGRenderer
import Foundation
import SVGPDFKit
import XCTest

/// Covers the ABC → SVG → PDF pipeline that `BuildService` drives.
///
/// `BuildService` itself is not directly testable — it needs a git checkout, a
/// database, and Box/Slack clients — so these tests exercise the same library
/// calls it makes, in the same order, on an inline tune. They exist mainly to
/// catch the failure modes the CeolKit migration introduced: a renderer that
/// cannot find its bundled fonts, a page count that no longer maps one-to-one
/// onto PDF pages, and a rasteriser that substitutes fonts instead of resolving
/// them.
final class ConversionPipelineTests: XCTestCase {

    /// A minimal two-tune pipe band source: a `%%ceolkit:pipeformat` directive
    /// (which is how bagpipe engraving is now requested), embellishments, and
    /// enough music to be worth engraving.
    private let sampleABC = """
    %abc-2.2
    %%ceolkit:pipeformat true
    %%footer "Page $P\tTest Tune"
    X:1
    T:Test March
    R:March
    M:4/4
    L:1/8
    K:D
    {g}Ad | {gfg}f2 {e}fa {e}f2 {g}ed | {gf}g2 {a}g<a {A}B2 {gde}d>B |
    {g}A2 {GAG}Ad {g}f<a df | {gf}g>f d<{e}B {gef}e2 {g}Ad |]
    """

    func testParseProducesScoreWithoutErrors() throws {
        let parsed = CeolKitParser().parse(sampleABC, options: .default)

        let errors = parsed.diagnostics.filter { $0.severity == .error }
        XCTAssertTrue(
            errors.isEmpty,
            "Unexpected parse errors: \(errors.map(\.message).joined(separator: "; "))"
        )
        XCTAssertFalse(parsed.hasErrors)
        XCTAssertEqual(parsed.score.tunes.count, 1)
        XCTAssertEqual(parsed.score.tunes.first?.titles.first?.value, "Test March")
    }

    /// The renderer loads Bravura and Libertinus Serif via `Bundle.module`. If the
    /// SwiftPM resource bundle is not deployed alongside the binary this throws,
    /// which is precisely the packaging regression the Dockerfile guards against.
    func testRenderProducesOneCompleteSVGDocumentPerPage() throws {
        let parsed = CeolKitParser().parse(sampleABC, options: .default)
        let pages = try SVGRenderer(config: .init(pageSize: .letter)).render(parsed.score)

        XCTAssertFalse(pages.isEmpty, "Renderer returned no pages")
        for (index, page) in pages.enumerated() {
            XCTAssertTrue(page.contains("<svg"), "Page \(index) has no opening <svg> tag")
            XCTAssertTrue(page.hasSuffix("</svg>"), "Page \(index) is not a complete document")
            XCTAssertEqual(
                page.components(separatedBy: "</svg>").count - 1, 1,
                "Page \(index) contains more than one SVG document; "
                + "the one-SVG-per-page contract SVGPDFKit relies on is broken"
            )
        }
    }

    /// The full `BuildService` conversion, end to end: parse, render, and hand the
    /// pages to SVGPDFKit as an ordered `[SVGSource]`.
    func testRenderedPagesConvertToPDF() throws {
        let parsed = CeolKitParser().parse(sampleABC, options: .default)
        let pages = try SVGRenderer(config: .init(pageSize: .letter)).render(parsed.score)

        let sources = pages.map { SVGSource.data(Data($0.utf8)) }
        let pdf = try SVGPDFConverter().convert(sources: sources)

        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)), "Output is not a PDF")
        XCTAssertGreaterThan(pdf.count, 1_000, "PDF is implausibly small")
    }

    /// A PDF that converts cleanly can still be unreadable: if the rasteriser
    /// silently substitutes a font, the output is a valid PDF of staff lines and
    /// stems with no noteheads, clefs, rests, or accidentals. `%PDF` and a
    /// plausible byte count do not catch that — this does.
    ///
    /// CeolKit embeds every face in the SVG as an `@font-face` base64 data URI,
    /// but librsvg ignores `@font-face` entirely and resolves `font-family` only
    /// through fontconfig. The faces must therefore be installed system-wide, as
    /// the Dockerfile's runtime stage and this workflow's CI job both do. Without
    /// that, `fc-match Bravura` returns DejaVu Sans, which has no glyphs at any of
    /// the SMuFL codepoints the score uses.
    func testConvertedPDFEmbedsTheBundledFontsRatherThanSubstitutes() throws {
        #if canImport(CoreGraphics)
        throw XCTSkip("""
            Not applicable on Apple platforms: SVGPDFKit rasterises in-process \
            through CoreGraphics, which converts every glyph to a vector outline. \
            The PDF embeds no fonts at all, so there is nothing to assert. This \
            failure mode belongs to the Linux rsvg-convert path.
            """)
        #else
        let parsed = CeolKitParser().parse(sampleABC, options: .default)
        let pages = try SVGRenderer(config: .init(pageSize: .letter)).render(parsed.score)
        let pdf = try SVGPDFConverter().convert(sources: pages.map { SVGSource.data(Data($0.utf8)) })

        // Latin-1 maps every byte to exactly one scalar and never fails, so the
        // ASCII font dictionaries survive the binary content streams around them.
        // librsvg's PDF backend writes those dictionaries uncompressed, so no
        // stream has to be inflated to read them.
        let text = String(data: pdf, encoding: .isoLatin1) ?? ""

        // Embedded subsets are named "ABCDEF+Bravura"; drop the subset tag.
        let fonts = text
            .matches(of: /\/BaseFont\s*\/(?:[A-Z]{6}\+)?([A-Za-z0-9\-]+)/)
            .map { String($0.1) }

        XCTAssertFalse(fonts.isEmpty, "PDF embeds no fonts at all")

        XCTAssertTrue(
            fonts.contains("Bravura"),
            "Bravura is not embedded — every notehead, clef, rest, and accidental "
            + "in this PDF is missing or wrong. Embedded fonts: \(Set(fonts).sorted())"
        )
        XCTAssertTrue(
            fonts.contains { $0.hasPrefix("LibertinusSerif") },
            "Libertinus Serif is not embedded; titles and footers rasterised in "
            + "some other face. Embedded fonts: \(Set(fonts).sorted())"
        )

        // Any other family means fontconfig substituted something.
        let substituted = Set(fonts.filter {
            $0 != "Bravura" && !$0.hasPrefix("LibertinusSerif")
        })
        XCTAssertTrue(
            substituted.isEmpty,
            "Fonts were substituted rather than resolved: \(substituted.sorted()). "
            + "Install the CeolKit faces where fontconfig can find them."
        )
        #endif
    }

    /// `I:abc-include` is the replacement for ABCKit's `includedFiles:` argument,
    /// and it only resolves when the parser is given a base directory — which is
    /// why `BuildService` builds one parser per ABC file.
    func testIncludeResolvesRelativeToBaseDirectory() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ceolkit-include-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "R:March\n".write(
            to: tempDir.appendingPathComponent("common.abh"),
            atomically: true,
            encoding: .utf8
        )

        let source = """
        %abc-2.2
        X:1
        T:Included Tune
        I:abc-include common.abh
        M:4/4
        L:1/8
        K:D
        {g}A2 {g}d2 {g}f2 {g}a2 |]
        """

        let parser = CeolKitParser(for: tempDir, fileResolver: CeolKitParser.defaultFileResolver)
        let parsed = parser.parse(source, options: .default)

        XCTAssertFalse(
            parsed.diagnostics.contains { $0.code == .includeFileNotFound
                || $0.code == .includeNoBaseDirectory },
            "Include did not resolve against the base directory"
        )
        XCTAssertEqual(parsed.score.tunes.first?.metadata.rhythm?.value, "March")
    }
}
