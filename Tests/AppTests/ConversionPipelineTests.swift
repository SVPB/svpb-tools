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
/// catch the two failure modes the CeolKit migration introduced: a renderer that
/// cannot find its bundled fonts, and a page count that no longer maps one-to-one
/// onto PDF pages.
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
