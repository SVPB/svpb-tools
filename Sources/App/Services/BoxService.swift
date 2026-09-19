import AsyncHTTPClient
import Fluent
import Foundation
import NIOCore
import NIOHTTP1
import Vapor

// MARK: - BoxService
//
// Responsible for all interaction with the Box REST API.
//
// Box folder layout managed by TNG:
//
//   pipe_music/          ← BOX_FOLDER_ID points here (top-level, pre-existing)
//   ├── 2025/            ← created on first build of the "2025" branch
//   │   └── 2025_binder.pdf
//   └── 2026/            ← created on first build of the "2026" branch
//       ├── 2026_binder.pdf
//       └── 2026_spec.pdf
//
// Only the binders `binders.yaml` declares are uploaded, each under its `output:`
// filename (C5). Per-tune PDFs are build intermediates and personalised binders are
// downloaded from TNG itself; neither ever reaches Box. The Gen.1 subdirectory
// structure (full_band/, g3/, g4/) is intentionally not reproduced.
//
// Key operations performed in sequence during a build:
//   1. resolveYearFolder(branch:)  — list the children of pipe_music; return the
//      existing year folder's ID, or create it and return the new one.
//   2. uploadFile(at:toFolder:)    — upload a binder into the year folder. A binder
//      that is already there gets a new *version* rather than a second file, so the
//      Box link the band has bookmarked keeps working and its history is the record
//      of what changed.

actor BoxService {

    // MARK: Configuration

    private let clientID: String
    private let clientSecret: String
    private let rootFolderID: String       // ID of the pipe_music Box folder
    private let db: any Database

    /// `BOX_REFRESH_TOKEN` from the environment: the token to use when the database
    /// has none, i.e. on a deployment that has never refreshed.
    private let seedRefreshToken: String
    /// The current refresh token, once it has been read or rotated. Box invalidates the
    /// previous one on every refresh, so this is the only usable copy and it is written
    /// through to `settings` as soon as it changes.
    private var refreshToken: String?
    private var accessToken: String?
    private var tokenExpiry: Date?

    private let httpClient: HTTPClient
    private let logger: Logger

    /// Refresh this long before the access token actually expires, so a slow upload
    /// cannot start on a token that dies mid-transfer.
    private static let expiryMargin: TimeInterval = 300

    /// Box's maximum page size for a folder listing.
    private static let pageSize = 1000

    // MARK: Init

    init(
        clientID: String,
        clientSecret: String,
        rootFolderID: String,
        refreshToken: String,
        db: any Database,
        httpClient: HTTPClient,
        logger: Logger
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.rootFolderID = rootFolderID
        self.seedRefreshToken = refreshToken
        self.db = db
        self.httpClient = httpClient
        self.logger = logger
    }

    // MARK: - Public API

    /// Upload `pdfURL` to the year subfolder of `pipe_music` that corresponds to `branch`.
    ///
    /// - The year folder is created automatically if it does not yet exist.
    /// - A file of the same name already in the folder gets a new version rather than
    ///   being duplicated.
    /// - Parameters:
    ///   - pdfURL:  Local path of the PDF to upload.
    ///   - branch:  Git branch name (used as the year subfolder name, e.g. `"2026"`).
    /// - Returns: The Box ID of the year folder, which is what a link to the band's
    ///   binders for that year is built from.
    @discardableResult
    func upload(pdf pdfURL: URL, forBranch branch: String) async throws -> String {
        do {
            return try await performUpload(pdf: pdfURL, forBranch: branch)
        } catch BoxError.unauthorized {
            // An access token can be revoked or expire early; one refresh is cheaper
            // than failing a build over it.
            logger.info("[Box] Access token rejected; refreshing and retrying once")
            accessToken = nil
            tokenExpiry = nil
            return try await performUpload(pdf: pdfURL, forBranch: branch)
        }
    }

    /// The Box web URL of the year folder for `branch`, for the build notification.
    nonisolated static func folderURL(id: String) -> String {
        "https://app.box.com/folder/\(id)"
    }

    private func performUpload(pdf pdfURL: URL, forBranch branch: String) async throws -> String {
        let token = try await validAccessToken()
        let yearFolderID = try await resolveYearFolder(branch: branch, token: token)
        try await uploadFile(at: pdfURL, toFolder: yearFolderID, token: token)
        return yearFolderID
    }

    // MARK: - Folder resolution

    /// Returns the Box folder ID for `branch` inside `pipe_music`, creating it
    /// via the API if it does not already exist.
    private func resolveYearFolder(branch: String, token: String) async throws -> String {
        if let existing = try await item(named: branch, ofType: "folder",
                                         inFolder: rootFolderID, token: token) {
            logger.debug("[Box] Year folder '\(branch)' is \(existing)")
            return existing
        }
        logger.info("[Box] No year folder '\(branch)' in pipe_music (\(rootFolderID)); creating it")
        return try await createYearFolder(named: branch, token: token)
    }

    /// Creates a subfolder named `name` inside `pipe_music` and returns its ID.
    private func createYearFolder(named name: String, token: String) async throws -> String {
        struct Parent: Encodable { let id: String }
        struct Body: Encodable { let name: String; let parent: Parent }
        struct Created: Decodable { let id: String }

        var request = HTTPClientRequest(url: "https://api.box.com/2.0/folders")
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: try JSONEncoder().encode(
            Body(name: name, parent: Parent(id: rootFolderID)))))

        let response = try await execute(request, timeout: .seconds(30))
        // Two builds of two branches can race here, and the loser is not in trouble:
        // the folder it wanted now exists.
        if response.status == .conflict {
            logger.info("[Box] Year folder '\(name)' was created concurrently; using the existing one")
            guard let existing = try await item(named: name, ofType: "folder",
                                                inFolder: rootFolderID, token: token) else {
                throw BoxError.http(status: response.status.code, body: response.text)
            }
            return existing
        }
        try response.orThrow()
        return try response.decode(Created.self).id
    }

    // MARK: - Folder listing

    struct ItemsPage: Decodable {
        struct Entry: Decodable {
            let type: String
            let id: String
            let name: String
        }
        let entries: [Entry]
        let totalCount: Int?

        enum CodingKeys: String, CodingKey {
            case entries
            case totalCount = "total_count"
        }
    }

    /// The ID of the item named `name` of `type` ("folder" or "file") in `folderID`,
    /// or `nil` when the folder holds no such item.
    ///
    /// Names are compared case-insensitively because Box itself treats `A.pdf` and
    /// `a.pdf` as the same name — uploading the second as a new file would be rejected,
    /// not accepted as a sibling.
    private func item(named name: String, ofType type: String,
                      inFolder folderID: String, token: String) async throws -> String? {
        var offset = 0
        while true {
            let url = "https://api.box.com/2.0/folders/\(folderID)/items"
                + "?fields=id,name,type&limit=\(Self.pageSize)&offset=\(offset)"
            var request = HTTPClientRequest(url: url)
            request.method = .GET
            request.headers.add(name: "Authorization", value: "Bearer \(token)")

            let response = try await execute(request, timeout: .seconds(30))
            try response.orThrow()
            let page = try response.decode(ItemsPage.self)

            if let match = Self.firstMatch(named: name, ofType: type, in: page.entries) {
                return match
            }

            offset += page.entries.count
            guard !page.entries.isEmpty, offset < (page.totalCount ?? offset) else { return nil }
        }
    }

    /// The ID of the first entry named `name` of `type`, comparing names the way Box
    /// does: without regard to case, so `A.pdf` and `a.pdf` are the same file and
    /// uploading the second as a new one would be rejected rather than accepted as a
    /// sibling. Type-scoped, so a folder cannot stand in for a file of the same name.
    static func firstMatch(named name: String, ofType type: String,
                           in entries: [ItemsPage.Entry]) -> String? {
        entries.first { $0.type == type && $0.name.lowercased() == name.lowercased() }?.id
    }

    // MARK: - File upload

    /// Upload a single PDF to `folderID`, versioning any file already there by that name.
    private func uploadFile(at url: URL, toFolder folderID: String, token: String) async throws {
        let name = url.lastPathComponent
        let contents = try Data(contentsOf: url)
        let existingID = try await item(named: name, ofType: "file", inFolder: folderID, token: token)

        // A binder that is already in Box gets a new version of the same file: the band's
        // link keeps working, and Box's version history becomes the record of what each
        // build changed. A fresh upload of the same name would simply be rejected.
        let endpoint = existingID.map { "https://upload.box.com/api/2.0/files/\($0)/content" }
            ?? "https://upload.box.com/api/2.0/files/content"
        let attributes = existingID == nil
            ? try Self.attributesJSON(name: name, parentID: folderID)
            : try Self.attributesJSON(name: name, parentID: nil)

        let boundary = "tng-\(UUID().uuidString)"
        var request = HTTPClientRequest(url: endpoint)
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")
        request.body = .bytes(ByteBuffer(bytes: Self.multipartBody(
            boundary: boundary, attributes: attributes, filename: name, contents: contents)))

        let versioning = existingID.map { " as a new version of file \($0)" } ?? ""
        logger.info("[Box] Uploading \(name) (\(contents.count) bytes) to folder \(folderID)\(versioning)")
        let response = try await execute(request, timeout: .minutes(5))
        try response.orThrow()
        logger.info("[Box] Uploaded \(name)")
    }

    /// The `attributes` part of a Box upload: the filename, and the parent folder for a
    /// file Box has not seen before. A new version of an existing file has a parent already.
    static func attributesJSON(name: String, parentID: String?) throws -> Data {
        struct Parent: Encodable { let id: String }
        struct Attributes: Encodable { let name: String; let parent: Parent? }
        return try JSONEncoder().encode(
            Attributes(name: name, parent: parentID.map(Parent.init(id:))))
    }

    /// A `multipart/form-data` body carrying Box's `attributes` JSON and the file itself.
    ///
    /// Built here rather than by a library because it is the one multipart request in the
    /// server, and because a pure function over bytes is testable without a network.
    static func multipartBody(boundary: String, attributes: Data,
                              filename: String, contents: Data) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"attributes\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(attributes)
        append("\r\n--\(boundary)\r\n")
        // Box reads the part's own `filename`; `attributes.name` is what the file is
        // stored as. They are the same here, and a quote in either would break the
        // header, so the only names that reach this point are the bare `.pdf`
        // filenames `BinderDefinitionLoader` allows.
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/pdf\r\n\r\n")
        body.append(contents)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    // MARK: - OAuth2 token management

    /// Returns a valid access token, refreshing via the Box token endpoint if needed.
    private func validAccessToken() async throws -> String {
        if let token = accessToken, let expiry = tokenExpiry, expiry > Date() {
            return token
        }
        return try await refreshAccessToken()
    }

    /// The refresh token to present to Box: the rotated one from the database, falling
    /// back to the `BOX_REFRESH_TOKEN` seed on a deployment that has never refreshed.
    private func currentRefreshToken() async throws -> String {
        if let token = refreshToken { return token }

        let stored: String?
        do {
            stored = try await Setting.value(for: Setting.boxRefreshToken, on: db)
        } catch {
            // A database that cannot be read is a bigger problem than this call, but
            // the seed may still get the build through.
            logger.error("[Box] Could not read the stored refresh token: \(error)")
            stored = nil
        }

        guard let token = stored ?? (seedRefreshToken.isEmpty ? nil : seedRefreshToken) else {
            throw BoxError.noRefreshToken
        }
        if stored == nil {
            logger.info("[Box] No stored refresh token; using the BOX_REFRESH_TOKEN seed")
        }
        refreshToken = token
        return token
    }

    private func refreshAccessToken() async throws -> String {
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresIn: Int

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }

        logger.info("[Box] Refreshing the access token")
        let current = try await currentRefreshToken()

        var request = HTTPClientRequest(url: "https://api.box.com/oauth2/token")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        request.body = .bytes(ByteBuffer(string: [
            "grant_type=refresh_token",
            "refresh_token=\(current)",
            "client_id=\(clientID)",
            "client_secret=\(clientSecret)",
        ].joined(separator: "&")))

        let response = try await execute(request, timeout: .seconds(30))
        guard response.status == .ok else {
            // A refresh token that Box will not accept cannot be recovered from here:
            // someone has to run `box-auth` again. Say so, rather than leaving the
            // operator to work it out from a 400.
            logger.error("[Box] Token refresh failed (\(response.status.code)): \(response.text)")
            throw BoxError.refreshRejected(body: response.text)
        }

        let decoded = try response.decode(TokenResponse.self)
        accessToken = decoded.accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(decoded.expiresIn) - Self.expiryMargin)

        // Box has just invalidated the token we presented, so the new one is now the only
        // way back in. Record it before it is used for anything.
        refreshToken = decoded.refreshToken
        do {
            try await Setting.set(Setting.boxRefreshToken, to: decoded.refreshToken, on: db)
        } catch {
            // The upload can still go ahead — but the next restart would reach for a token
            // Box has retired, so this is an error, not a warning.
            logger.error("[Box] Could not persist the rotated refresh token; a restart will need `box-auth` run again: \(error)")
        }
        return decoded.accessToken
    }

    // MARK: - HTTP

    /// A collected Box response: everything the caller needs without holding a stream.
    private struct BoxResponse {
        let status: HTTPResponseStatus
        let body: Data

        var text: String { String(data: body, encoding: .utf8) ?? "<\(body.count) bytes>" }

        /// Throws unless Box accepted the request.
        func orThrow() throws {
            guard !(200..<300).contains(Int(status.code)) else { return }
            if status == .unauthorized { throw BoxError.unauthorized }
            throw BoxError.http(status: status.code, body: text)
        }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            do {
                return try JSONDecoder().decode(type, from: body)
            } catch {
                throw BoxError.unexpectedBody(text)
            }
        }
    }

    private func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws -> BoxResponse {
        let response = try await httpClient.execute(request, timeout: timeout)
        let buffer = try await response.body.collect(upTo: 8 * 1024 * 1024)
        return BoxResponse(status: response.status, body: Data(buffer: buffer))
    }
}

// MARK: - BoxError

enum BoxError: Error, CustomStringConvertible {
    /// Neither the database nor the environment has a refresh token to present.
    case noRefreshToken
    /// Box rejected the refresh token; only a fresh `box-auth` run can fix it.
    case refreshRejected(body: String)
    /// Box rejected the access token. Retried once before it reaches a caller.
    case unauthorized
    case http(status: UInt, body: String)
    case unexpectedBody(String)

    var description: String {
        switch self {
        case .noRefreshToken:
            return "No Box refresh token: set BOX_REFRESH_TOKEN, or run `box-auth` to obtain one"
        case .refreshRejected(let body):
            return "Box rejected the refresh token — run `box-auth` to issue a new one: \(body)"
        case .unauthorized:
            return "Box rejected the access token"
        case .http(let status, let body):
            return "HTTP \(status) from Box: \(body)"
        case .unexpectedBody(let body):
            return "Unexpected response body from Box: \(body)"
        }
    }
}
