import AsyncHTTPClient
import Foundation
import Vapor

// MARK: - BoxService
//
// Responsible for all interaction with the Box REST API.
//
// Box folder layout managed by TNG:
//
//   pipe_music/          ← BOX_FOLDER_ID points here (top-level, pre-existing)
//   ├── 2025/            ← created on first build of the "2025" branch
//   │   ├── Amazing Grace.pdf
//   │   └── Scotland the Brave.pdf
//   └── 2026/            ← created on first build of the "2026" branch
//       └── ...
//
// The Gen.1 subdirectory structure (full_band/, g3/, g4/) is intentionally
// not reproduced.  All PDFs for a given year sit directly in the year folder.
//
// Key operations performed in sequence during a build (C4):
//   1. resolveYearFolder(branch:)  — list children of pipe_music; return the
//      existing year folder ID, or create it and return the new ID.
//   2. upload(pdfURL:toFolder:)    — upload a single PDF into the year folder,
//      replacing any existing file with the same name.

actor BoxService {

    // MARK: Configuration

    private let clientID: String
    private let clientSecret: String
    private let rootFolderID: String       // ID of the pipe_music Box folder
    private var refreshToken: String       // rotated automatically on each token refresh
    private var accessToken: String?
    private var tokenExpiry: Date?

    private let httpClient: HTTPClient
    private let logger: Logger

    // MARK: Init

    init(
        clientID: String,
        clientSecret: String,
        rootFolderID: String,
        refreshToken: String,
        httpClient: HTTPClient,
        logger: Logger
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.rootFolderID = rootFolderID
        self.refreshToken = refreshToken
        self.httpClient = httpClient
        self.logger = logger
    }

    // MARK: - Public API

    /// Upload `pdfURL` to the year subfolder of `pipe_music` that corresponds to `branch`.
    ///
    /// - The year folder is created automatically if it does not yet exist.
    /// - If a file with the same name already exists in the folder it is replaced.
    /// - Parameters:
    ///   - pdfURL:  Local path of the PDF to upload.
    ///   - branch:  Git branch name (used as the year subfolder name, e.g. `"2026"`).
    func upload(pdf pdfURL: URL, forBranch branch: String) async throws {
        let token = try await validAccessToken()
        let yearFolderID = try await resolveYearFolder(branch: branch, token: token)
        try await uploadFile(at: pdfURL, toFolder: yearFolderID, token: token)
    }

    // MARK: - Folder resolution

    /// Returns the Box folder ID for `branch` inside `pipe_music`, creating it
    /// via the API if it does not already exist.
    private func resolveYearFolder(branch: String, token: String) async throws -> String {
        // Phase 1 TODO: GET https://api.box.com/2.0/folders/{rootFolderID}/items
        //   Filter items where type == "folder" && name == branch.
        //   If found, return item.id.
        //   If not found, fall through to createYearFolder.
        logger.info("BoxService: resolving year folder for branch '\(branch)'")
        return try await createYearFolder(named: branch, token: token)
    }

    /// Creates a subfolder named `name` inside `pipe_music` and returns its ID.
    private func createYearFolder(named name: String, token: String) async throws -> String {
        // Phase 1 TODO: POST https://api.box.com/2.0/folders
        //   Body: { "name": name, "parent": { "id": rootFolderID } }
        //   Returns the new folder's id.
        logger.info("BoxService: creating year folder '\(name)' inside pipe_music (\(rootFolderID))")
        throw Abort(.notImplemented, reason: "BoxService.createYearFolder not yet implemented")
    }

    // MARK: - File upload

    /// Upload a single PDF to `folderID`, replacing any existing file with the same name.
    private func uploadFile(at url: URL, toFolder folderID: String, token: String) async throws {
        // Phase 1 TODO: Check whether a file with this name already exists in folderID.
        //   • If yes:  PUT  https://upload.box.com/api/2.0/files/{fileID}/content
        //   • If no:   POST https://upload.box.com/api/2.0/files/content
        //              multipart/form-data with attributes JSON + file binary.
        logger.info("BoxService: uploading \(url.lastPathComponent) to folder \(folderID)")
        throw Abort(.notImplemented, reason: "BoxService.uploadFile not yet implemented")
    }

    // MARK: - OAuth2 token management

    /// Returns a valid access token, refreshing via the Box token endpoint if needed.
    /// The new refresh token is persisted back to the in-memory state; Phase 1 will
    /// also write it to the database so it survives a restart.
    private func validAccessToken() async throws -> String {
        if let token = accessToken, let expiry = tokenExpiry, expiry > Date() {
            return token
        }
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        // Phase 1 TODO: POST https://api.box.com/oauth2/token
        //   grant_type=refresh_token
        //   client_id, client_secret, refresh_token
        //   → store response.access_token, update refreshToken, set tokenExpiry = now + 3600s
        //   → persist the new refresh_token to the DB (so a server restart doesn't invalidate it)
        logger.info("BoxService: refreshing Box access token")
        throw Abort(.notImplemented, reason: "BoxService.refreshAccessToken not yet implemented")
    }
}
