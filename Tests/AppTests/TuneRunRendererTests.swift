import CeolKitParser
import CeolKitSVGRenderer
import Foundation
import XCTest
@testable import App

/// Covers packing a run of tunes into one document (#48): what is written into the ABC
/// that CeolKit is handed, and what comes back out of it.
///
/// The two halves are tested separately on purpose. Whether two short tunes end up on one
/// sheet is CeolKit's decision and is checked here only as the end of the contract; what
/// this type is actually responsible for is handing CeolKit a document that says the same
/// thing about each tune as that tune's own file did — which is a question about text, and
/// is asked of `concatenate(_:firstPageNumber:)` directly.
final class TuneRunRendererTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tune-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Building the document

    /// The whole point of the exercise: a file's preamble governs that file's tunes, so
    /// laid beside another file it has to move into its own tunes' headers. `%%ceolkit:scale`
    /// in the first tune's header is a statement about the first tune (ABC v2.2 §4.23); in
    /// the document preamble it would resize the second one too.
    func testAPreambleIsHoistedIntoItsOwnTunesHeaders() {
        let scaled = TuneRunRenderer.takeApart("""
        %abc-2.2
        %%ceolkit:scale 0.85
        X:1
        T:A
        K:D
        AB |]

        """, includesRelativeTo: directory)
        let plain = TuneRunRenderer.takeApart("""
        %abc-2.2
        X:1
        T:B
        K:D
        cd |]

        """, includesRelativeTo: directory)

        XCTAssertEqual(TuneRunRenderer.concatenate([scaled, plain], firstPageNumber: 5), """
        %abc-2.2
        %%ceolkit:pagenumber 5
        X:1
        %%ceolkit:scale 0.85
        T:A
        K:D
        AB |]

        X:2
        T:B
        K:D
        cd |]


        """)
    }

    /// `%%ceolkit:pagenumber` goes ahead of everything, so a tune that sets its own page
    /// number still wins — the same rule `TunePageRenderer` follows for one tune.
    func testThePageNumberIsClampedAndWrittenFirst() {
        let document = TuneRunRenderer.takeApart("X:1\nK:D\nAB |]\n", includesRelativeTo: directory)
        let run = TuneRunRenderer.concatenate([document], firstPageNumber: 0)
        XCTAssertTrue(run.hasPrefix("%%ceolkit:pagenumber 1\nX:1\n"), run)
    }

    /// A style sheet is read and inlined rather than left as an `I:abc-include` for CeolKit
    /// to expand. In the file preamble it was written for, a blank line in it means nothing;
    /// hoisted into a tune header, it would end the header and cut the tune in half.
    func testAnIncludedStyleSheetIsInlinedWithoutItsBlankLines() throws {
        try """
        %%footer "$P"

        %%flatbeams true
        """.write(to: directory.appendingPathComponent("style.abh"), atomically: true, encoding: .utf8)

        let document = TuneRunRenderer.takeApart("""
        %abc-2.2
        I:abc-include style.abh
        X:1
        K:D
        AB |]
        """, includesRelativeTo: directory)

        XCTAssertEqual(document.hoisted, [#"%%footer "$P""#, "%%flatbeams true"])
    }

    /// An include that cannot be read is left where it stands: CeolKit resolves it the same
    /// way and says so far better than a silent omission would.
    func testAnUnreadableIncludeIsLeftForCeolKitToReport() {
        let document = TuneRunRenderer.takeApart("""
        %abc-2.2
        I:abc-include nowhere.abh
        X:1
        K:D
        AB |]
        """, includesRelativeTo: directory)

        XCTAssertEqual(document.hoisted, ["I:abc-include nowhere.abh"])
    }

    /// A page cannot change size part-way down, so CeolKit honours `%%landscape` only beside
    /// a page break. The run states the first file's orientation in the preamble — where it
    /// is not a change but the size the document opens at — and writes `%%newpage` beside
    /// every later change.
    func testAnOrientationChangeIsWrittenWithThePageBreakItNeeds() {
        let landscape = TuneRunRenderer.takeApart("%abc-2.2\n%%landscape 1\nX:1\nK:D\nAB |]\n",
                                                  includesRelativeTo: directory)
        let portrait = TuneRunRenderer.takeApart("%abc-2.2\n%%landscape 0\nX:1\nK:D\ncd |]\n",
                                                 includesRelativeTo: directory)

        XCTAssertEqual(landscape.landscape, true)
        XCTAssertEqual(portrait.landscape, false)
        XCTAssertFalse(landscape.hoisted.contains { $0.contains("landscape") },
                       "a %%landscape with no break beside it is dropped by CeolKit with a diagnostic")

        let run = TuneRunRenderer.concatenate([landscape, portrait], firstPageNumber: 1)
        XCTAssertTrue(run.hasPrefix("%abc-2.2\n%%ceolkit:pagenumber 1\n%%landscape 1\nX:1\n"), run)
        XCTAssertTrue(run.contains("X:2\n%%newpage\n%%landscape 0\n"), run)
    }

    /// Two files that agree about the orientation are not interrupted by it — a break there
    /// would cost exactly the page packing set out to save.
    func testAgreeingOrientationsAreNotBrokenBetween() {
        let first = TuneRunRenderer.takeApart("%abc-2.2\n%%landscape 1\nX:1\nK:D\nAB |]\n",
                                              includesRelativeTo: directory)
        let second = TuneRunRenderer.takeApart("%abc-2.2\n%%landscape 1\nX:1\nK:D\ncd |]\n",
                                               includesRelativeTo: directory)
        XCTAssertFalse(TuneRunRenderer.concatenate([first, second], firstPageNumber: 1)
            .contains("%%newpage"))
    }

    /// A directive written below one tune is written for what comes after it, so it is
    /// carried to the next tune's header rather than left between them — where the parser
    /// would read it as a statement about the whole run, earlier tunes included.
    func testADirectiveBelowATuneIsCarriedToTheNextOne() {
        let document = TuneRunRenderer.takeApart("""
        %abc-2.2
        X:1
        K:D
        AB |]

        %%ceolkit:scale 0.7

        X:2
        K:D
        cd |]
        """, includesRelativeTo: directory)

        XCTAssertEqual(document.tunes.count, 2)
        XCTAssertEqual(document.tunes[0].carried, [])
        XCTAssertEqual(document.tunes[1].carried, ["%%ceolkit:scale 0.7"])
    }

    // MARK: - What CeolKit makes of it

    /// The end of the contract, and the reason for the issue: two tunes that each took a
    /// whole page on their own come back sharing one.
    func testTwoShortTunesShareAPage() throws {
        let rendering = try TuneRunRenderer().render(
            [try source("first", music: "ABcd efga |]"),
             try source("second", music: "gfed cBAG |]")],
            firstPageNumber: 1)

        XCTAssertEqual(rendering.pages.count, 1)
        XCTAssertEqual(rendering.starts, [0, 0])
        XCTAssertTrue(rendering.printsPageNumbers)
    }

    /// A tune the page cannot hold still opens one of its own, which is what keeps packing
    /// a saving rather than a rearrangement.
    func testATuneTooTallToShareOpensItsOwnPage() throws {
        let tall = Array(repeating: "ABcd efga | gfed cBAG |", count: 20).joined(separator: "\n")
        let rendering = try TuneRunRenderer().render(
            [try source("short", music: "ABcd efga |]"),
             try source("tall", music: tall + "|]")],
            firstPageNumber: 1)

        XCTAssertGreaterThan(rendering.pages.count, 1)
        XCTAssertEqual(rendering.starts[0], 0)
        XCTAssertEqual(rendering.starts[1], 1, "a tune that cannot fit under the one before it opens a page")
    }

    /// The run opens at the binder page it was given and numbers on from there, so a packed
    /// run sits in a binder's numbering exactly as a single tune does.
    func testTheRunOpensAtThePageItWasGiven() throws {
        let tall = Array(repeating: "ABcd efga | gfed cBAG |", count: 20).joined(separator: "\n")
        let rendering = try TuneRunRenderer().render(
            [try source("tall", music: tall + "|]"),
             try source("short", music: "ABcd efga |]")],
            firstPageNumber: 17)

        XCTAssertEqual(printedPageNumbers(rendering.pages).first, 17)
        XCTAssertEqual(printedPageNumbers(rendering.pages),
                       Array(17 ..< 17 + rendering.pages.count))
    }

    /// `%%footer` is written in a file preamble and CeolKit scopes it to the tune that opens
    /// a page. Hoisted correctly, each tune keeps its own; left in the document preamble,
    /// the last one written would govern the lot.
    func testAPreambleFooterDoesNotReachTheNextTune() throws {
        let first = try source("first", music: "ABcd |]", footer: "FIRST $P")
        let second = try source("second", music: "efga |]", footer: "SECOND $P")
        let documents = [first, second].map {
            TuneRunRenderer.takeApart(try! String(contentsOf: $0.url, encoding: .utf8),
                                      includesRelativeTo: directory)
        }
        let parsed = CeolKitParser().parse(
            TuneRunRenderer.concatenate(documents, firstPageNumber: 1), options: .default)

        XCTAssertEqual(parsed.score.tunes.map(\.footer), ["FIRST $P", "SECOND $P"])
        XCTAssertNil(parsed.score.footer, "nothing should be left governing the whole run")
    }

    /// A run reports whether *every* tune in it asks for a page number, because the drawn
    /// number is outlines and a footer that prints none looks exactly like one that does.
    func testAFooterWithNoPageNumberTokenIsReported() throws {
        let rendering = try TuneRunRenderer().render(
            [try source("numbered", music: "ABcd |]", footer: "$P"),
             try source("silent", music: "efga |]", footer: "Generated")],
            firstPageNumber: 1)
        XCTAssertFalse(rendering.printsPageNumbers)
    }

    /// A source file holding several tunes contributes all of them, and is listed at the
    /// page its first one opens on.
    func testAFileOfSeveralTunesContributesAllOfThem() throws {
        let url = directory.appendingPathComponent("pair.abc")
        try """
        %abc-2.2
        %%footer "$P"
        X:1
        T:One
        M:4/4
        L:1/8
        K:D
        ABcd |]

        X:2
        T:Two
        M:4/4
        L:1/8
        K:D
        efga |]
        """.write(to: url, atomically: true, encoding: .utf8)

        let rendering = try TuneRunRenderer().render(
            [TuneRunRenderer.Source(slug: "pair", url: url),
             try source("third", music: "gfed |]")],
            firstPageNumber: 1)

        XCTAssertEqual(rendering.starts.count, 2, "one start per source, not per tune")
        XCTAssertEqual(rendering.starts, [0, 0])
    }

    /// A run of nothing is not a run, and a file with no `X:` cannot be placed in one —
    /// both leave the caller to fall back to engraving one tune at a time.
    func testARunThatCannotBeBuiltSaysSo() throws {
        XCTAssertThrowsError(try TuneRunRenderer().render([], firstPageNumber: 1))

        let url = directory.appendingPathComponent("empty.abc")
        try "%abc-2.2\n% nothing here\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TuneRunRenderer().render(
            [TuneRunRenderer.Source(slug: "empty", url: url)], firstPageNumber: 1))
    }

    // MARK: - Helpers

    /// Writes one tune's ABC into the run's directory and names it as a source.
    private func source(_ slug: String, music: String, footer: String = "$P") throws
        -> TuneRunRenderer.Source {
        let url = directory.appendingPathComponent("\(slug).abc")
        try """
        %abc-2.2
        %%footer "\(footer)"
        X:1
        T:\(slug)
        M:4/4
        L:1/8
        K:D
        \(music)
        """.write(to: url, atomically: true, encoding: .utf8)
        return TuneRunRenderer.Source(slug: slug, url: url)
    }

    /// What each page prints as its page number, read from the `ceolkit-meta` comment —
    /// the only thing in an engraved page that still says the number in digits.
    private func printedPageNumbers(_ pages: [String]) -> [Int] {
        pages.compactMap { page in
            page.firstMatch(of: /ceolkit-meta: \{"page": (\d+)/).flatMap { Int($0.1) }
        }
    }
}
