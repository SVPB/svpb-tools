import CeolKitParser
import CeolKitSVGRenderer
import Foundation
import XCTest
@testable import App

/// Covers the one thing `TunePageRenderer` adds to a tune's ABC, and that CeolKit
/// reads it back as the page number the document opens on (#19).
final class TunePageRendererTests: XCTestCase {

    /// `%abc-2.2` has to stay the first line of the file, so the directive goes after it.
    func testTheDirectiveGoesAfterTheVersionLine() {
        let numbered = TunePageRenderer.numbering("%abc-2.2\nI:abc-include style.abh\nX:1\n", from: 17)
        XCTAssertEqual(numbered, "%abc-2.2\n%%ceolkit:pagenumber 17\nI:abc-include style.abh\nX:1\n")
    }

    /// A file that declares no version starts with the directive.
    func testAFileWithNoVersionLineGetsTheDirectiveFirst() {
        let numbered = TunePageRenderer.numbering("X:1\nT:No Preamble\n", from: 3)
        XCTAssertEqual(numbered, "%%ceolkit:pagenumber 3\nX:1\nT:No Preamble\n")
    }

    /// A version line with nothing after it is still a version line.
    func testAVersionLineIsTheWholeFile() {
        XCTAssertEqual(TunePageRenderer.numbering("%abc-2.2", from: 2),
                       "%%ceolkit:pagenumber 2\n%abc-2.2")
    }

    /// `%%ceolkit:pagenumber` rejects anything below 1 and would leave the document
    /// numbering from 1 anyway, so a nonsensical offset is clamped rather than emitted.
    func testAPageNumberBelowOneIsClamped() {
        XCTAssertEqual(TunePageRenderer.numbering("X:1\n", from: 0), "%%ceolkit:pagenumber 1\nX:1\n")
    }

    // MARK: - Section labels (#67)

    /// The label goes in beside the page number, and after it: both are the binder's, and
    /// both have to come before anything the file says so the file's own still wins.
    func testTheLabelFollowsThePageNumber() {
        let labelled = TunePageRenderer.numbering("%abc-2.2\nX:1\n", from: 4, label: "Reels")
        XCTAssertEqual(labelled, "%abc-2.2\n%%ceolkit:pagenumber 4\n%%ceolkit:label \"Reels\"\nX:1\n")
    }

    /// A tune in an untitled section is given no label at all, not an empty one.
    func testNoLabelWritesNoDirective() {
        XCTAssertFalse(TunePageRenderer.numbering("X:1\n", from: 1, label: nil).contains("label"))
    }

    /// CeolKit keeps everything between the enclosing quotes as written, so a `"` in a
    /// section name is written as it is: a backslash would be printed, not read as an escape.
    func testAQuoteInTheNameComesBackAsWritten() {
        for name in [#"The "Big" Set"#, #"""#, #""Quoted""#, "100% Reels"] {
            XCTAssertEqual(labels(TunePageRenderer.numbering(Self.tune, from: 1, label: name)), [name])
        }
    }

    /// A file that names its own label keeps it: ours is written first, and the last one in
    /// a header is the one CeolKit uses.
    func testTheFilesOwnLabelWins() {
        let own = "%abc-2.2\n%%ceolkit:label \"Mine\"\n" + Self.tune.dropFirst("%abc-2.2\n".count)
        XCTAssertEqual(labels(TunePageRenderer.numbering(own, from: 1, label: "Binder")).last, "Mine")
    }

    private static let tune = "%abc-2.2\nX:1\nT:T\nM:4/4\nL:1/4\nK:C\nCDEF|\n"

    /// Every `%%ceolkit:label` the parsed tune carries, in the order they apply.
    private func labels(_ abc: String) -> [String] {
        let tune = CeolKitParser().parse(abc, options: .default).score.tunes.first
        return (tune?.directives ?? []).compactMap {
            guard case .label(let text) = $0.directive else { return nil }
            return text
        }
    }

    // MARK: - Does the footer ask for a number at all?

    /// Both style sheets in `svpb-music` are covered: `style.abh` prints no page number,
    /// `ckstyle.abh` prints `${pagenumber}`. Telling them apart is the whole point — the
    /// engraved pages look the same either way, because a drawn number is outlines.
    func testAFooterIsRecognisedAsPrintingAPageNumberOrNot() {
        XCTAssertTrue(TunePageRenderer.printsAPageNumber(#"\tPage ${pagenumber}\tGenerated: $D"#))
        XCTAssertTrue(TunePageRenderer.printsAPageNumber(#"$P\t\tGenerated: $D"#))
        // CeolKit matches a mark's name without regard to case.
        XCTAssertTrue(TunePageRenderer.printsAPageNumber("${PageNumber}"))

        XCTAssertFalse(TunePageRenderer.printsAPageNumber(#"\t\tGenerated: $D"#))
        XCTAssertFalse(TunePageRenderer.printsAPageNumber("${pagecount}"))
        // `%%footer ""` suppresses a footer; no footer at all prints nothing either.
        XCTAssertFalse(TunePageRenderer.printsAPageNumber(""))
        XCTAssertFalse(TunePageRenderer.printsAPageNumber(nil))
    }

    /// A tune whose footer carries no page-number token still renders, still occupies its
    /// pages, and says that it prints no number.
    func testAFooterWithNoPageNumberTokenIsReported() throws {
        let rendering = try render(footer: #"\t\tGenerated: $D"#)
        XCTAssertEqual(rendering.pages.count, 1)
        XCTAssertFalse(rendering.printsPageNumbers)
    }

    /// `${pagenumber}` is the token the real corpus uses, and its default value follows
    /// `%%ceolkit:pagenumber` exactly as `$P` does — which is what lets a binder ask CeolKit
    /// to draw the number rather than trying to stamp it afterwards.
    func testTheSubstitutableMarkFollowsTheDirective() throws {
        let rendering = try render(footer: #"\tPage ${pagenumber}\t"#, firstPageNumber: 34)
        XCTAssertTrue(rendering.printsPageNumbers)
        let page = try XCTUnwrap(rendering.pages.first)
        XCTAssertTrue(page.contains(#"id="ceolkit-tag-pagenumber""#),
                      "CeolKit no longer wraps the mark in a findable group")
        let match = try XCTUnwrap(page.firstMatch(of: /ceolkit-meta: \{"page": (\d+)/))
        XCTAssertEqual(Int(match.1), 34)
    }

    private func render(footer: String, firstPageNumber: Int = 1) throws -> TunePageRenderer.Rendering {
        let abc = """
        %abc-2.2
        %%footer "\(footer)"
        X:1
        T:Footer
        M:4/4
        L:1/8
        K:D
        ABcd efga | gfed cBAG |]
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("footer-\(UUID().uuidString).abc")
        try abc.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try TunePageRenderer().render(abcAt: url, firstPageNumber: firstPageNumber)
    }

    /// The end of the contract: CeolKit prints the number the directive asked for.
    func testCeolKitEngravesTheRequestedPageNumber() throws {
        let abc = """
        %abc-2.2
        %%footer "$P"
        X:1
        T:Offset
        M:4/4
        L:1/8
        K:D
        ABcd efga | gfed cBAG |]
        """
        let parsed = CeolKitParser().parse(TunePageRenderer.numbering(abc, from: 17), options: .default)
        let pages = try SVGRenderer(config: .init(pageSize: .letter)).render(parsed.score)

        let page = try XCTUnwrap(pages.first)
        let match = try XCTUnwrap(page.firstMatch(of: /ceolkit-meta: \{"page": (\d+)/),
                                  "CeolKit no longer records the printed page number")
        XCTAssertEqual(Int(match.1), 17)
        XCTAssertTrue(page.contains(#"class="footer""#), "The page lost its footer")
    }
}
