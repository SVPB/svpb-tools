import Foundation
import XCTest
@testable import App

/// The parts of the Google Drive destination that can be checked without Google (#88).
///
/// As with `BoxUploadTests`, the request plumbing is exercised against the real API by
/// hand rather than through a stub HTTP layer. What is covered here is what Drive's own
/// behaviour makes easy to get wrong: its query language's quoting, names that are not
/// unique, refresh tokens that are not rotated, and a root folder TNG must not quietly
/// replace.
final class GoogleDriveTests: XCTestCase {

    // MARK: - files.list query

    func testTheQueryFindsUntrashedFoldersOfTheNameInTheParent() {
        XCTAssertEqual(
            GoogleDriveService.listQuery(named: "2026", in: "ROOT", folders: true),
            "name = '2026' and 'ROOT' in parents and "
                + "mimeType = 'application/vnd.google-apps.folder' and trashed = false")
    }

    /// A binder lookup must not find a folder of the same name, nor a folder lookup a file.
    func testTheQueryForAFileExcludesFolders() {
        XCTAssertEqual(
            GoogleDriveService.listQuery(named: "2026_binder.pdf", in: "F", folders: false),
            "name = '2026_binder.pdf' and 'F' in parents and "
                + "mimeType != 'application/vnd.google-apps.folder' and trashed = false")
    }

    /// An apostrophe would end the quoted name early; a backslash would escape whatever
    /// followed it.
    func testQuotesAndBackslashesInANameAreEscaped() {
        XCTAssertEqual(GoogleDriveService.escaped("Pipers' Tunes"), #"Pipers\' Tunes"#)
        XCTAssertEqual(GoogleDriveService.escaped(#"a\b"#), #"a\\b"#)
        XCTAssertEqual(GoogleDriveService.escaped(#"\'"#), #"\\\'"#,
                       "The backslash is escaped first, or the quote's escape is doubled")
        XCTAssertTrue(
            GoogleDriveService.listQuery(named: "Pipers' Tunes", in: "R", folders: true)
                .hasPrefix(#"name = 'Pipers\' Tunes' and"#))
    }

    // MARK: - Create or update

    private static let listingJSON = """
    {
      "files": [
        { "id": "older", "name": "2026_binder.pdf" },
        { "id": "newer", "name": "2026_binder.pdf" }
      ]
    }
    """

    func testAFileListingDecodes() throws {
        let files = try JSONDecoder().decode(
            GoogleDriveService.FileList.self, from: Data(Self.listingJSON.utf8)).files
        XCTAssertEqual(files.map(\.id), ["older", "newer"])
    }

    func testABinderNotYetInTheFolderIsCreatedThere() {
        XCTAssertEqual(GoogleDriveService.uploadPlan(folder: "YEAR", existing: []),
                       .create(parent: "YEAR"))
    }

    /// Drive allows two files of one name. The first listed — the oldest, since the listing
    /// is ordered by creation — is the one that gets the new revision, every time.
    func testABinderAlreadyThereIsUpdatedInPlace() throws {
        let files = try JSONDecoder().decode(
            GoogleDriveService.FileList.self, from: Data(Self.listingJSON.utf8)).files
        XCTAssertEqual(GoogleDriveService.uploadPlan(folder: "YEAR", existing: files),
                       .update(fileID: "older"))
    }

    // MARK: - Links

    func testFolderURLPointsAtTheFolder() {
        XCTAssertEqual(GoogleDriveService.folderURL(id: "1AbC"),
                       "https://drive.google.com/drive/folders/1AbC")
    }

    // MARK: - Tokens

    /// Google normally answers a refresh with no refresh token, meaning the one presented
    /// is still good. Treating that as "no token" would lose the credential.
    func testATokenResponseWithoutARefreshTokenKeepsTheExistingOne() throws {
        let response = try JSONDecoder().decode(
            GoogleDriveService.TokenResponse.self,
            from: Data(#"{"access_token":"ya29.x","expires_in":3599,"token_type":"Bearer"}"#.utf8))
        XCTAssertNil(response.refreshToken)

        XCTAssertEqual(
            GoogleDriveService.refreshTokenToKeep(issued: response.refreshToken, current: "1//held"),
            "1//held")
    }

    func testAnIssuedRefreshTokenReplacesTheExistingOne() {
        XCTAssertEqual(GoogleDriveService.refreshTokenToKeep(issued: "1//new", current: "1//old"),
                       "1//new")
        XCTAssertEqual(GoogleDriveService.refreshTokenToKeep(issued: "", current: "1//old"),
                       "1//old")
        XCTAssertNil(GoogleDriveService.refreshTokenToKeep(issued: nil, current: nil))
    }

    /// Without offline access there is no refresh token at all, and without forced consent
    /// an account that granted access before gets none on re-authorisation.
    func testTheConsentRequestAsksForARefreshTokenWithTheNarrowScope() throws {
        let url = try XCTUnwrap(URLComponents(string: GoogleDriveService.authorizationURL(
            clientID: "client", redirectURI: "https://tng.example/google-drive-callback",
            state: "S")))
        let items = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["prompt"], "consent")
        XCTAssertEqual(items["scope"], "https://www.googleapis.com/auth/drive.file")
        XCTAssertEqual(items["redirect_uri"], "https://tng.example/google-drive-callback")
        XCTAssertEqual(items["state"], "S")
        XCTAssertEqual(items["response_type"], "code")
    }

    // MARK: - Root folder

    func testWithNoStoredRootFolderTheFirstPublishCreatesOne() {
        XCTAssertEqual(GoogleDriveService.rootFolderPlan(storedID: nil), .create)
        XCTAssertEqual(GoogleDriveService.rootFolderPlan(storedID: " "), .create)
        XCTAssertEqual(GoogleDriveService.rootFolderPlan(storedID: "ROOT"), .verify(id: "ROOT"))
    }

    func testAStoredRootFolderThatIsStillThereIsUsed() throws {
        let found = GoogleDriveService.FileResource(id: "ROOT", name: "pipe_music", trashed: false)
        XCTAssertEqual(
            try GoogleDriveService.checkedRootFolder(id: "ROOT", named: "pipe_music", found: found),
            "ROOT")
    }

    /// The band has shared the folder TNG made. A fresh one would be shared with nobody,
    /// so a folder that has gone is an error naming it, not a cue to make another.
    func testADeletedRootFolderIsAnErrorNotANewFolder() {
        XCTAssertThrowsError(
            try GoogleDriveService.checkedRootFolder(id: "ROOT", named: "pipe_music", found: nil)
        ) { error in
            guard case GoogleDriveError.rootFolderMissing(let id, let name) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(id, "ROOT")
            XCTAssertEqual(name, "pipe_music")
            XCTAssertTrue("\(error)".contains("pipe_music (ROOT)"), "\(error)")
        }
    }

    func testATrashedRootFolderIsAnErrorNotANewFolder() {
        let trashed = GoogleDriveService.FileResource(id: "ROOT", name: "pipe_music", trashed: true)
        XCTAssertThrowsError(
            try GoogleDriveService.checkedRootFolder(id: "ROOT", named: "pipe_music", found: trashed))
    }
}
