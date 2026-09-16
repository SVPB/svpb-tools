import XCTest
@testable import App

/// The Slack build notification is the band's main signal that new PDFs exist,
/// so each status has to read differently — a partial build must not look green.
final class BuildNotificationTests: XCTestCase {

    func testSuccessListsFilesWithoutWarning() {
        let text = SlackService.buildNotificationText(
            branch: "2026", status: .success, files: ["A.pdf", "B.pdf"])

        XCTAssertEqual(text, "✅ *Build success* — branch `2026`\n• A.pdf\n• B.pdf")
    }

    func testPartialIsFlaggedAndPointsAtTheLog() {
        let text = SlackService.buildNotificationText(
            branch: "2026", status: .partial, files: ["A.pdf"])

        XCTAssertTrue(text.hasPrefix("⚠️ *Build partial* — branch `2026`\n"))
        XCTAssertTrue(text.contains("see the build log"))
        XCTAssertFalse(text.contains("✅"))
        XCTAssertTrue(text.hasSuffix("• A.pdf"))
    }

    func testFailureWithNoFiles() {
        let text = SlackService.buildNotificationText(
            branch: "2026", status: .failure, files: [])

        XCTAssertEqual(text, "❌ *Build failure* — branch `2026`\n_(no files)_")
    }
}
