import XCTest
@testable import App

/// The Slack build notification is the band's main signal that new PDFs exist,
/// so each status has to read differently — a partial build must not look green —
/// and what it names is the binders, not the per-tune PDFs they were made from.
final class BuildNotificationTests: XCTestCase {

    func testSuccessNamesTheBindersAndLinksBox() {
        let text = SlackService.buildNotificationText(
            branch: "2026", status: .success,
            files: ["2026_binder.pdf", "2026_spec.pdf"],
            boxFolderURL: "https://app.box.com/folder/111")

        XCTAssertEqual(text, """
        ✅ *Build success* — branch `2026`
        Binders rebuilt:
        • 2026_binder.pdf
        • 2026_spec.pdf
        <https://app.box.com/folder/111|Open the 2026 folder in Box>
        """)
    }

    /// A build that never reached Box has nowhere to link to, and says so by
    /// leaving the link out rather than offering a dead one.
    func testSuccessWithoutABoxFolderOmitsTheLink() {
        let text = SlackService.buildNotificationText(
            branch: "2026", status: .success, files: ["2026_binder.pdf"])

        XCTAssertEqual(text, """
        ✅ *Build success* — branch `2026`
        Binders rebuilt:
        • 2026_binder.pdf
        """)
    }

    /// Old builds' notifications are never replayed — a "build succeeded" arriving hours
    /// late is worse than silence — so a catch-up is reported by the build that did it.
    func testCatchUpUploadsAreNamedSeparately() {
        let text = SlackService.buildNotificationText(
            branch: "2026", status: .success,
            files: ["2026_spec.pdf"],
            boxFolderURL: "https://app.box.com/folder/111",
            alsoUploaded: ["2026_binder.pdf"])

        XCTAssertEqual(text, """
        ✅ *Build success* — branch `2026`
        Binders rebuilt:
        • 2026_spec.pdf
        Also uploaded, held over from an earlier build:
        • 2026_binder.pdf
        <https://app.box.com/folder/111|Open the 2026 folder in Box>
        """)
    }

    func testPartialIsFlaggedAndPointsAtTheLog() {
        let text = SlackService.buildNotificationText(
            branch: "2026", status: .partial, files: ["2026_binder.pdf"])

        XCTAssertTrue(text.hasPrefix("⚠️ *Build partial* — branch `2026`\n"))
        XCTAssertTrue(text.contains("see the build log"))
        XCTAssertFalse(text.contains("✅"))
        XCTAssertTrue(text.hasSuffix("• 2026_binder.pdf"))
    }

    /// A branch with no `binders.yaml`, or a build that assembled nothing, produced
    /// no binders — which is different from producing files nobody hears about.
    func testFailureWithNoBinders() {
        let text = SlackService.buildNotificationText(
            branch: "2026", status: .failure, files: [])

        XCTAssertEqual(text, "❌ *Build failure* — branch `2026`\n_(no binders)_")
    }
}
