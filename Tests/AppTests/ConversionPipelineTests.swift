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
/// onto PDF pages, and glyphs that reach the page as host-resolved text instead
/// of geometry.
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

    /// The renderer reads Bravura and Libertinus Serif from `Bundle.module` to
    /// extract glyph outlines. If the SwiftPM resource bundle is not deployed
    /// alongside the binary this throws, which is precisely the packaging
    /// regression the Dockerfile guards against.
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

    /// A page that converts cleanly can still be unreadable: a rasteriser that
    /// cannot resolve the music face produces a valid PDF of staff lines and stems
    /// with no noteheads, clefs, rests, or accidentals. `%PDF` and a plausible byte
    /// count do not catch that — this does.
    ///
    /// As of CeolKit 1.2 the renderer defaults to `TextRendering.outlines`: every
    /// glyph is written into the document as geometry — a `<path>` in `<defs>`, drawn
    /// by a `<use>` — and no `@font-face` block or `<text>` element is emitted at all.
    /// That is what makes the output host-independent, since no non-browser
    /// rasteriser honours `@font-face` and each resolves `font-family` through a font
    /// database the document cannot populate. The contract to defend is therefore
    /// that the geometry is present and self-contained, not that some face got
    /// embedded downstream.
    func testGlyphsAreEmittedAsSelfContainedOutlines() throws {
        let parsed = CeolKitParser().parse(sampleABC, options: .default)
        let pages = try SVGRenderer(config: .init(pageSize: .letter)).render(parsed.score)
        let page = try XCTUnwrap(pages.first, "Renderer returned no pages")

        // Either of these means the renderer fell back to the font-face route, and
        // the page is only correct on a host that installed the faces out of band.
        XCTAssertFalse(
            page.contains("@font-face"),
            "Page carries an @font-face block; no non-browser rasteriser honours it"
        )
        XCTAssertFalse(
            page.contains("<text"),
            "Page paints <text>, which resolves through the host font database "
            + "rather than the geometry in the document"
        )

        // Glyph outlines are defined once per glyph and referenced by id. The face
        // prefix comes from `OutlineFontSet.FaceKey`. A non-empty `d` is part of the
        // match: a defs entry with no path data draws nothing.
        let defined = Set(
            page.matches(of: /<path id="([A-Za-z]+-g\d+)" d="[^"]+"/).map { String($0.1) }
        )
        XCTAssertTrue(
            defined.contains { $0.hasPrefix("bravura-") },
            "No Bravura outlines defined — every notehead, clef, rest, and accidental "
            + "on this page is missing. Defined faces: \(faceNames(of: defined))"
        )
        XCTAssertTrue(
            defined.contains { $0.hasPrefix("libertinusSerif") },
            "No Libertinus Serif outlines defined; the title and footer are missing. "
            + "Defined faces: \(faceNames(of: defined))"
        )

        // A `<use>` pointing at an id that was never defined draws nothing, which is
        // exactly the silent, still-a-valid-PDF failure this test exists to catch.
        let drawn = page.matches(of: /<use href="#([^"]+)"/).map { String($0.1) }
        XCTAssertFalse(drawn.isEmpty, "Outlines are defined but none are drawn")
        XCTAssertTrue(
            Set(drawn).subtracting(defined).isEmpty,
            "Glyphs reference undefined outlines and will not be drawn: "
            + "\(Set(drawn).subtracting(defined).sorted())"
        )
    }

    /// The other half of the outlines contract, on the only platform where it can be
    /// broken silently: nothing in the converted PDF may depend on a host font.
    ///
    /// On Apple platforms SVGPDFKit rasterises in-process through CoreGraphics, which
    /// reduces glyphs to vector outlines whatever the input, so this would pass
    /// without proving anything. On Linux it shells out to rsvg-convert, and a font
    /// dictionary in the output means some run reached the page as text and was
    /// resolved — or substituted — through fontconfig.
    func testConvertedPDFDependsOnNoHostFont() throws {
        #if canImport(CoreGraphics)
        throw XCTSkip("""
            Not applicable on Apple platforms: CoreGraphics converts every glyph to a \
            vector outline regardless of how the SVG expressed it, so an empty font \
            list here says nothing about the renderer. This belongs to the Linux \
            rsvg-convert path.
            """)
        #else
        let parsed = CeolKitParser().parse(sampleABC, options: .default)
        let pages = try SVGRenderer(config: .init(pageSize: .letter)).render(parsed.score)
        let pdf = try SVGPDFConverter().convert(sources: pages.map { SVGSource.data(Data($0.utf8)) })

        // Latin-1 maps every byte to exactly one scalar and never fails, so the ASCII
        // font dictionaries survive the binary content streams around them. librsvg's
        // PDF backend writes those dictionaries uncompressed, so no stream has to be
        // inflated to read them.
        let text = String(data: pdf, encoding: .isoLatin1) ?? ""

        // Embedded subsets are named "ABCDEF+Bravura"; drop the subset tag.
        let fonts = Set(
            text.matches(of: /\/BaseFont\s*\/(?:[A-Z]{6}\+)?([A-Za-z0-9\-]+)/).map { String($0.1) }
        )

        XCTAssertTrue(
            fonts.isEmpty,
            "PDF embeds fonts: \(fonts.sorted()). Glyphs reached the page as text "
            + "rather than geometry, so this output is only correct on a host whose "
            + "font database happens to match."
        )
        #endif
    }

    /// The distinct face prefixes among a set of `<defs>` glyph ids, for failure output.
    private func faceNames(of ids: Set<String>) -> String {
        let faces = Set(ids.compactMap { $0.split(separator: "-g").first.map(String.init) })
        return faces.isEmpty ? "none" : faces.sorted().joined(separator: ", ")
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
