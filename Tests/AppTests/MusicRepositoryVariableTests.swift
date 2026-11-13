import Foundation
import XCTest
@testable import App

/// `ORG_MUSIC_REPO_URL` names the music repository; `SVPB_MUSIC_REPO_URL`, its name before
/// #89, is still read when it is unset.
final class MusicRepositoryVariableTests: XCTestCase {

    private func repo(_ env: [String: String]) -> (url: String, variable: String)? {
        GitService.repoURL(from: { env[$0] })
    }

    func testTheNewNameIsRead() {
        let found = repo(["ORG_MUSIC_REPO_URL": "https://github.com/Band/music.git"])
        XCTAssertEqual(found?.url, "https://github.com/Band/music.git")
        XCTAssertEqual(found?.variable, "ORG_MUSIC_REPO_URL")
    }

    func testTheOldNameIsReadWhenTheNewOneIsUnset() {
        let found = repo(["SVPB_MUSIC_REPO_URL": "https://github.com/SVPB/svpb-music.git"])
        XCTAssertEqual(found?.url, "https://github.com/SVPB/svpb-music.git")
        XCTAssertEqual(found?.variable, "SVPB_MUSIC_REPO_URL")
    }

    /// `.env.example` leaves the new name empty; an empty one must not hide the old one.
    func testTheOldNameIsReadWhenTheNewOneIsBlank() {
        let found = repo(["ORG_MUSIC_REPO_URL": " ",
                          "SVPB_MUSIC_REPO_URL": "https://github.com/SVPB/svpb-music.git"])
        XCTAssertEqual(found?.variable, "SVPB_MUSIC_REPO_URL")
    }

    func testTheNewNameWinsWhenBothAreSet() {
        let found = repo(["ORG_MUSIC_REPO_URL": "https://github.com/Band/music.git",
                          "SVPB_MUSIC_REPO_URL": "https://github.com/SVPB/svpb-music.git"])
        XCTAssertEqual(found?.url, "https://github.com/Band/music.git")
    }

    func testNeitherSetIsNil() {
        XCTAssertNil(repo([:]))
    }

    // MARK: - The repository's name

    private func name(_ url: String) -> String? {
        GitService(repoURL: url, workspaceBase: URL(fileURLWithPath: NSTemporaryDirectory())).repoName
    }

    func testTheNameIsTheLastPathComponentWithoutGit() {
        XCTAssertEqual(name("https://github.com/SVPB/svpb-music.git"), "svpb-music")
        XCTAssertEqual(name("https://github.com/Band/tunes"), "tunes")
        XCTAssertEqual(name("https://x-access-token:ghp_secret@github.com/Band/tunes.git"), "tunes")
        XCTAssertEqual(name("git@github.com:Band/tunes.git"), "tunes")
    }

    func testNoRepositoryHasNoName() {
        XCTAssertNil(name(""))
    }
}
