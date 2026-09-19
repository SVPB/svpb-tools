import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// The parts of the Box upload path that can be checked without Box.
///
/// `BoxService`'s request/response plumbing is exercised against the real API by the
/// tunnel workflow in the README, not here: it is one caller, and a stub HTTP layer
/// built for it would test the stub. What is covered here is everything Box's own
/// behaviour makes easy to get subtly wrong — the multipart body it parses, the
/// attributes that decide upload-versus-new-version, its case-insensitive names, and
/// the refresh token that has to outlive the process.
final class BoxUploadTests: XCTestCase {

    // MARK: - Multipart body

    func testMultipartBodyCarriesAttributesAndFile() throws {
        let attributes = try BoxService.attributesJSON(name: "2026_binder.pdf", parentID: "123")
        let contents = Data("%PDF-1.7 not really".utf8)

        let body = BoxService.multipartBody(
            boundary: "BOUNDARY", attributes: attributes,
            filename: "2026_binder.pdf", contents: contents)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("--BOUNDARY\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"attributes\"\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n\r\n{"))
        XCTAssertTrue(text.contains(
            "Content-Disposition: form-data; name=\"file\"; filename=\"2026_binder.pdf\"\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/pdf\r\n\r\n%PDF-1.7 not really"))
        XCTAssertTrue(text.hasSuffix("\r\n--BOUNDARY--\r\n"),
                      "The closing boundary needs its trailing --, or Box sees a truncated body")
    }

    /// The file part is bytes, not text: a PDF is not UTF-8 and must survive verbatim.
    func testMultipartBodyDoesNotAlterTheFileBytes() throws {
        let contents = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFF, 0xFE, 0x0D, 0x0A, 0x42])
        let body = BoxService.multipartBody(
            boundary: "B", attributes: Data("{}".utf8), filename: "x.pdf", contents: contents)

        let marker = Data("application/pdf\r\n\r\n".utf8)
        let start = try XCTUnwrap(body.range(of: marker)).upperBound
        let end = try XCTUnwrap(body.range(of: Data("\r\n--B--\r\n".utf8))).lowerBound
        XCTAssertEqual(body[start..<end], contents)
    }

    // MARK: - Attributes

    /// A file Box has not seen needs to be told where it goes; a new version of one it
    /// already has must not be told, or Box reads it as a move.
    func testAttributesNameTheParentOnlyForANewFile() throws {
        let fresh = try JSONSerialization.jsonObject(
            with: BoxService.attributesJSON(name: "a.pdf", parentID: "42")) as? [String: Any]
        XCTAssertEqual(fresh?["name"] as? String, "a.pdf")
        XCTAssertEqual((fresh?["parent"] as? [String: Any])?["id"] as? String, "42")

        let version = try JSONSerialization.jsonObject(
            with: BoxService.attributesJSON(name: "a.pdf", parentID: nil)) as? [String: Any]
        XCTAssertEqual(version?["name"] as? String, "a.pdf")
        XCTAssertNil(version?["parent"])
    }

    // MARK: - Folder listing

    private static let itemsJSON = """
    {
      "total_count": 3,
      "entries": [
        { "type": "folder", "id": "111", "name": "2026" },
        { "type": "file",   "id": "222", "name": "2026_Binder.pdf" },
        { "type": "file",   "id": "333", "name": "2026_spec.pdf" }
      ],
      "offset": 0,
      "limit": 1000
    }
    """

    func testItemsPageDecodesABoxListing() throws {
        let page = try JSONDecoder().decode(
            BoxService.ItemsPage.self, from: Data(Self.itemsJSON.utf8))

        XCTAssertEqual(page.totalCount, 3)
        XCTAssertEqual(page.entries.map(\.id), ["111", "222", "333"])
    }

    /// Box compares filenames without regard to case, so a binder declared
    /// `2026_binder.pdf` has to find the `2026_Binder.pdf` already up there — otherwise
    /// TNG uploads it as a new file and Box rejects the name as taken.
    func testMatchingIsCaseInsensitiveAndScopedToTheType() throws {
        let entries = try JSONDecoder().decode(
            BoxService.ItemsPage.self, from: Data(Self.itemsJSON.utf8)).entries

        XCTAssertEqual(BoxService.firstMatch(named: "2026_binder.pdf", ofType: "file", in: entries),
                       "222")
        XCTAssertEqual(BoxService.firstMatch(named: "2026", ofType: "folder", in: entries), "111")
        XCTAssertNil(BoxService.firstMatch(named: "2026", ofType: "file", in: entries),
                     "The year folder is not a file of the same name")
        XCTAssertNil(BoxService.firstMatch(named: "nothing.pdf", ofType: "file", in: entries))
    }

    func testFolderURLPointsAtTheYearFolder() {
        XCTAssertEqual(BoxService.folderURL(id: "111"), "https://app.box.com/folder/111")
    }
}

// MARK: - BoxRefreshTokenTests

/// Box invalidates the old refresh token on every refresh, so the rotated one is the only
/// way back in and has to survive a restart. Holding it in actor state alone is what made
/// every restart reach for a token Box had already retired — and a token left unused for
/// 60 days expires outright, which is the failure this table exists to prevent.
final class BoxRefreshTokenTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testSettingStoresAndReplacesAValue() async throws {
        var stored = try await Setting.value(for: Setting.boxRefreshToken, on: app.db)
        XCTAssertNil(stored)

        try await Setting.set(Setting.boxRefreshToken, to: "first", on: app.db)
        stored = try await Setting.value(for: Setting.boxRefreshToken, on: app.db)
        XCTAssertEqual(stored, "first")

        try await Setting.set(Setting.boxRefreshToken, to: "second", on: app.db)
        stored = try await Setting.value(for: Setting.boxRefreshToken, on: app.db)
        XCTAssertEqual(stored, "second")

        let rows = try await Setting.query(on: app.db).count()
        XCTAssertEqual(rows, 1, "Rotating the token replaces it rather than accumulating rows")
    }
}
