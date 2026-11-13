import AsyncHTTPClient
import Fluent
import Foundation
import NIOCore
import NIOHTTP1
import Vapor

// MARK: - GoogleDriveService
//
// The second publishing destination (#88), for a band that keeps its music on Google Drive.
//
// Drive folder layout managed by TNG:
//
//   pipe_music/          ← GOOGLE_DRIVE_FOLDER_NAME; created by TNG on first publish
//   ├── 2025/            ← created on first build of the "2025" branch
//   │   └── 2025_binder.pdf
//   └── 2026/
//       ├── 2026_binder.pdf
//       └── 2026_spec.pdf
//
// TNG holds only the `drive.file` scope, which lets it see the files it created and
// nothing else. That is why it makes its own root folder rather than being pointed at one
// the band made by hand: it could not see that one. The root folder's ID is kept in
// `settings` as `google_drive.root_folder_id`, and the band shares the folder with its
// members from Drive.
//
// Drive differs from Box in two ways that shape this file:
//   - Names are not unique. Several items in a folder may share one, so every lookup
//     takes the first match, and folder creation is serialised so that TNG never makes a
//     second folder of a name while one exists.
//   - Refresh tokens are not rotated. A refresh normally returns no new refresh token, and
//     the one TNG has stays good; so when renewal last happened is recorded separately.

actor GoogleDriveService {

    // MARK: Configuration

    private let clientID: String
    private let clientSecret: String
    /// `GOOGLE_DRIVE_FOLDER_NAME`: what the root folder is called when TNG creates it.
    private let rootFolderName: String
    private let db: any Database

    /// `GOOGLE_REFRESH_TOKEN` from the environment: used only when the database has none.
    private let seedRefreshToken: String
    private var refreshToken: String?
    private var accessToken: String?
    private var tokenExpiry: Date?

    private let httpClient: HTTPClient
    private let logger: Logger

    /// Folder lookups in flight, by branch, so two builds asking for the same year folder
    /// at once share one lookup, and so at most one creation. The actor alone does not
    /// ensure this: it is re-entered at every `await`, which is exactly between "listed,
    /// none found" and "created". Only in-flight lookups are shared, not their results, so
    /// a folder deleted after it was found is noticed by the next publish.
    private var yearFolders: [String: InFlight] = [:]
    /// The same, for the root folder.
    private var rootFolder: InFlight?

    private struct InFlight {
        let id = UUID()
        let task: Task<String, any Error>
    }

    /// Refresh this long before the access token actually expires.
    private static let expiryMargin: TimeInterval = 300

    static let folderMimeType = "application/vnd.google-apps.folder"
    static let scope = "https://www.googleapis.com/auth/drive.file"

    // MARK: Init

    init(
        clientID: String,
        clientSecret: String,
        rootFolderName: String,
        refreshToken: String,
        db: any Database,
        httpClient: HTTPClient,
        logger: Logger
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.rootFolderName = rootFolderName
        self.seedRefreshToken = refreshToken
        self.db = db
        self.httpClient = httpClient
        self.logger = logger
    }

    // MARK: - Publishing

    /// Uploads `file` into the year folder for `branch`, replacing a file of the same name,
    /// and returns the year folder's ID.
    private func upload(_ file: URL, forBranch branch: String) async throws -> String {
        do {
            return try await performUpload(file, forBranch: branch)
        } catch GoogleDriveError.unauthorized {
            logger.info("[Google Drive] Access token rejected; refreshing and retrying once")
            accessToken = nil
            tokenExpiry = nil
            return try await performUpload(file, forBranch: branch)
        }
    }

    private func performUpload(_ file: URL, forBranch branch: String) async throws -> String {
        let folderID = try await yearFolder(for: branch)
        try await uploadFile(at: file, toFolder: folderID)
        return folderID
    }

    /// The Drive web URL of the folder whose ID is `id`.
    nonisolated static func folderURL(id: String) -> String {
        "https://drive.google.com/drive/folders/\(id)"
    }

    // MARK: - Root folder

    /// What to do about the root folder, given what `settings` holds.
    enum RootFolderPlan: Equatable {
        /// Nothing stored: this is the first publish, so make the folder.
        case create
        /// A folder was made before; check that it is still there and use it.
        case verify(id: String)
    }

    nonisolated static func rootFolderPlan(storedID: String?) -> RootFolderPlan {
        guard let id = storedID?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            return .create
        }
        return .verify(id: id)
    }

    /// The parts of a file resource TNG asks Drive for.
    struct FileResource: Decodable, Equatable {
        let id: String
        let name: String
        let trashed: Bool?
    }

    /// The stored root folder's ID, if Drive still has it.
    ///
    /// A folder that has gone — deleted, or in the trash — is an error rather than a cue to
    /// make another. The band has shared the old one with its members; a new one nobody can
    /// see would make every build look successful while delivering binders to no one.
    ///
    /// - Parameter found: The folder's resource, or `nil` when Drive answered 404.
    nonisolated static func checkedRootFolder(
        id: String, named name: String, found: FileResource?
    ) throws -> String {
        guard let found, found.trashed != true else {
            throw GoogleDriveError.rootFolderMissing(id: id, name: name)
        }
        return found.id
    }

    /// The root folder's ID, made on first publish.
    private func rootFolderID() async throws -> String {
        if let rootFolder { return try await rootFolder.task.value }
        let lookup = InFlight(task: Task { try await self.resolveRootFolder() })
        rootFolder = lookup
        defer { if rootFolder?.id == lookup.id { rootFolder = nil } }
        return try await lookup.task.value
    }

    private func resolveRootFolder() async throws -> String {
        let stored = try await Setting.value(for: Setting.googleDriveRootFolderID, on: db)
        switch Self.rootFolderPlan(storedID: stored) {
        case .verify(let id):
            return try Self.checkedRootFolder(
                id: id, named: rootFolderName, found: try await fileResource(id: id))
        case .create:
            guard !rootFolderName.isEmpty else {
                throw GoogleDriveError.unexpectedBody("GOOGLE_DRIVE_FOLDER_NAME is not set")
            }
            logger.notice("[Google Drive] No root folder yet; creating '\(rootFolderName)'")
            let id = try await createFolder(named: rootFolderName, parent: nil)
            try await Setting.set(Setting.googleDriveRootFolderID, to: id, on: db)
            logger.notice("[Google Drive] Created root folder '\(rootFolderName)' (\(id)). Share it with the band from Drive.")
            return id
        }
    }

    /// The resource for `id`, or `nil` when Drive has no such file that TNG can see.
    private func fileResource(id: String) async throws -> FileResource? {
        let response = try await get(
            "https://www.googleapis.com/drive/v3/files/\(id)?fields=id,name,trashed")
        if response.status == .notFound { return nil }
        try response.orThrow()
        return try response.decode(FileResource.self)
    }

    // MARK: - Year folders

    private func yearFolder(for branch: String) async throws -> String {
        if let existing = yearFolders[branch] { return try await existing.task.value }
        let lookup = InFlight(task: Task { try await self.resolveYearFolder(branch) })
        yearFolders[branch] = lookup
        defer { if yearFolders[branch]?.id == lookup.id { yearFolders[branch] = nil } }
        return try await lookup.task.value
    }

    /// The year folder for `branch` in the root folder: the first one Drive lists, or a new
    /// one when there is none.
    private func resolveYearFolder(_ branch: String) async throws -> String {
        let root = try await rootFolderID()
        let query = Self.listQuery(named: branch, in: root, folders: true)
        if let existing = try await list(query).first {
            logger.debug("[Google Drive] Year folder '\(branch)' is \(existing.id)")
            return existing.id
        }
        logger.info("[Google Drive] No year folder '\(branch)' in \(rootFolderName) (\(root)); creating it")
        return try await createFolder(named: branch, parent: root)
    }

    /// Creates a folder named `name` inside `parent` (or at the top of My Drive) and
    /// returns its ID.
    private func createFolder(named name: String, parent: String?) async throws -> String {
        struct Body: Encodable {
            let name: String
            let mimeType: String
            let parents: [String]?
        }
        var request = try await authorised(
            "https://www.googleapis.com/drive/v3/files?fields=id", method: .POST)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: try JSONEncoder().encode(
            Body(name: name, mimeType: Self.folderMimeType, parents: parent.map { [$0] }))))

        let response = try await execute(request, timeout: .seconds(30))
        try response.orThrow()
        return try response.decode(FileResource.self).id
    }

    // MARK: - Listing

    /// A `files.list` query for the untrashed items named `name` directly inside `parent`:
    /// folders only, or everything but folders.
    ///
    /// Drive's query language quotes strings with `'` and escapes with `\`, so both are
    /// escaped in the name — `Pipers' Tunes` would otherwise end the string early, and at
    /// worst turn the rest of the name into query syntax.
    nonisolated static func listQuery(named name: String, in parent: String, folders: Bool) -> String {
        let type = folders
            ? "mimeType = '\(folderMimeType)'"
            : "mimeType != '\(folderMimeType)'"
        return "name = '\(escaped(name))' and '\(escaped(parent))' in parents and \(type) and trashed = false"
    }

    nonisolated static func escaped(_ literal: String) -> String {
        literal.replacing("\\", with: "\\\\").replacing("'", with: "\\'")
    }

    struct FileList: Decodable {
        let files: [FileResource]
    }

    /// The items `query` matches, oldest first, so "the first" is the same one every time.
    private func list(_ query: String) async throws -> [FileResource] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "orderBy", value: "createdTime"),
            URLQueryItem(name: "pageSize", value: "10"),
            URLQueryItem(name: "spaces", value: "drive"),
        ]
        // URLComponents leaves `+` alone, which a query server reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacing("+", with: "%2B")
        let response = try await get(components.url!.absoluteString)
        try response.orThrow()
        return try response.decode(FileList.self).files
    }

    // MARK: - Upload

    /// Whether a binder is a new file or new content for one already there.
    enum UploadPlan: Equatable {
        case create(parent: String)
        case update(fileID: String)
    }

    /// The plan for a binder, given the listing of files of its name in its folder.
    ///
    /// An existing file gets new content, which Drive keeps as a new revision of the same
    /// file ID, so a link someone has bookmarked keeps working. When several files share
    /// the name, the first is the one updated, as with folders.
    nonisolated static func uploadPlan(folder: String, existing: [FileResource]) -> UploadPlan {
        existing.first.map { .update(fileID: $0.id) } ?? .create(parent: folder)
    }

    private func uploadFile(at url: URL, toFolder folderID: String) async throws {
        let name = url.lastPathComponent
        let contents = try Data(contentsOf: url)
        let plan = Self.uploadPlan(
            folder: folderID,
            existing: try await list(Self.listQuery(named: name, in: folderID, folders: false)))

        // A resumable upload, sent in one request. Drive's simpler multipart upload stops
        // at 5 MB, and a full band binder can be larger.
        struct Metadata: Encodable {
            let name: String?
            let mimeType: String?
            let parents: [String]?
        }
        let start: HTTPClientRequest
        let metadata: Metadata
        switch plan {
        case .create(let parent):
            start = try await authorised(
                "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id",
                method: .POST)
            metadata = Metadata(name: name, mimeType: "application/pdf", parents: [parent])
            logger.info("[Google Drive] Uploading \(name) (\(contents.count) bytes) to folder \(folderID)")
        case .update(let fileID):
            start = try await authorised(
                "https://www.googleapis.com/upload/drive/v3/files/\(fileID)?uploadType=resumable&fields=id",
                method: .PATCH)
            metadata = Metadata(name: nil, mimeType: nil, parents: nil)
            logger.info("[Google Drive] Uploading \(name) (\(contents.count) bytes) as a new revision of file \(fileID)")
        }

        var session = start
        session.headers.add(name: "Content-Type", value: "application/json; charset=UTF-8")
        session.headers.add(name: "X-Upload-Content-Type", value: "application/pdf")
        session.headers.add(name: "X-Upload-Content-Length", value: "\(contents.count)")
        session.body = .bytes(ByteBuffer(bytes: try JSONEncoder().encode(metadata)))
        let opened = try await execute(session, timeout: .seconds(30))
        try opened.orThrow()
        guard let location = opened.headers.first(name: "Location") else {
            throw GoogleDriveError.unexpectedBody("No upload session URI in the response: \(opened.text)")
        }

        var put = HTTPClientRequest(url: location)
        put.method = .PUT
        put.headers.add(name: "Content-Type", value: "application/pdf")
        put.headers.add(name: "Content-Length", value: "\(contents.count)")
        put.body = .bytes(ByteBuffer(bytes: contents))
        let response = try await execute(put, timeout: .minutes(10))
        try response.orThrow()
        logger.info("[Google Drive] Uploaded \(name)")
    }

    // MARK: - OAuth2 token management

    private func validAccessToken() async throws -> String {
        if let token = accessToken, let expiry = tokenExpiry, expiry > Date() {
            return token
        }
        return try await refreshAccessToken()
    }

    /// The stored refresh token, falling back to the `GOOGLE_REFRESH_TOKEN` seed.
    private func currentRefreshToken() async throws -> String? {
        if let refreshToken { return refreshToken }
        let stored: String?
        do {
            stored = try await Setting.value(for: Setting.googleDriveRefreshToken, on: db)
        } catch {
            logger.error("[Google Drive] Could not read the stored refresh token: \(error)")
            stored = nil
        }
        let token = stored ?? (seedRefreshToken.isEmpty ? nil : seedRefreshToken)
        refreshToken = token
        return token
    }

    /// What Google returns from either grant on the token endpoint. A refresh normally
    /// carries no `refresh_token`: Google keeps the existing one in force.
    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    /// The refresh token to hold after a grant: the one Google issued, or the one already
    /// held when it issued none. `nil` only when there is neither.
    nonisolated static func refreshTokenToKeep(issued: String?, current: String?) -> String? {
        if let issued, !issued.isEmpty { return issued }
        return current
    }

    private func refreshAccessToken() async throws -> String {
        guard let current = try await currentRefreshToken() else {
            throw GoogleDriveError.noRefreshToken
        }
        logger.info("[Google Drive] Refreshing the access token")

        var request = HTTPClientRequest(url: "https://oauth2.googleapis.com/token")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        request.body = .bytes(ByteBuffer(string: BoxService.formEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", current),
            ("client_id", clientID),
            ("client_secret", clientSecret),
        ])))

        let response = try await execute(request, timeout: .seconds(30))
        guard response.status == .ok else {
            logger.error("[Google Drive] Token refresh failed (\(response.status.code)): \(response.text)")
            throw GoogleDriveError.refreshRejected(body: response.text)
        }
        let decoded = try response.decode(TokenResponse.self)
        try await adopt(decoded, previous: current)
        return decoded.accessToken
    }

    /// Takes a grant into use, storing the refresh token when it is new and recording that
    /// the credential was renewed — which, since Google does not rotate the token, nothing
    /// else would show.
    private func adopt(_ tokens: TokenResponse, previous: String?) async throws {
        guard let keep = Self.refreshTokenToKeep(issued: tokens.refreshToken, current: previous) else {
            // Only an authorisation can get here: `prompt=consent` makes Google issue one,
            // so its absence means the consent request was not the one TNG built.
            throw GoogleDriveError.noRefreshToken
        }
        accessToken = tokens.accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn) - Self.expiryMargin)
        refreshToken = keep

        do {
            if keep != previous {
                try await Setting.set(Setting.googleDriveRefreshToken, to: keep, on: db)
            } else if try await Setting.value(for: Setting.googleDriveRefreshToken, on: db) == nil {
                // Still running on the .env seed: store it, so the database is the record.
                try await Setting.set(Setting.googleDriveRefreshToken, to: keep, on: db)
            }
        } catch {
            logger.critical("[Google Drive] A refresh token could not be stored, so it will be lost at the next restart: \(error)")
            throw GoogleDriveError.tokenNotPersisted("\(error)")
        }
        do {
            try await Setting.set(
                Setting.googleDriveTokenRenewedAt,
                to: Date().formatted(.iso8601), on: db)
        } catch {
            // Only the connections page's countdown depends on it.
            logger.warning("[Google Drive] Could not record the renewal time: \(error)")
        }
    }

    func renew() async throws {
        _ = try await refreshAccessToken()
    }

    // MARK: - Interactive authorisation

    nonisolated static func authorizationURL(clientID: String, redirectURI: String, state: String) -> String {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            // Offline access is what yields a refresh token at all; `prompt=consent`
            // makes Google issue a new one even to an account that has granted access
            // before, which a re-authorisation needs.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!.absoluteString
    }

    func adoptAuthorizationCode(_ code: String, redirectURI: String) async throws {
        var request = HTTPClientRequest(url: "https://oauth2.googleapis.com/token")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        request.body = .bytes(ByteBuffer(string: BoxService.formEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("redirect_uri", redirectURI),
        ])))

        let response = try await execute(request, timeout: .seconds(30))
        guard response.status == .ok else {
            logger.error("[Google Drive] Authorisation code exchange failed (\(response.status.code)): \(response.text)")
            throw GoogleDriveError.http(status: response.status.code, body: response.text)
        }
        try await adopt(try response.decode(TokenResponse.self), previous: try await currentRefreshToken())
        logger.notice("[Google Drive] Authorised; a refresh token is stored")
    }

    // MARK: - Status

    struct Status: Sendable {
        let hasStoredToken: Bool
        let lastRenewed: Date?
        let hasSeedToken: Bool
        /// The account TNG acts as, when Drive could be reached.
        let account: String?
        /// The stored root folder, if one has been made.
        let rootFolderID: String?
        /// Its name, when it is still there.
        let rootFolderName: String?
        let error: String?
        /// The stored root folder is gone, which needs a person to resolve.
        let rootFolderMissing: Bool
    }

    /// Asks Drive who TNG is signed in as and whether the root folder is still there.
    /// Creates nothing: making the root folder is the first publish's job.
    func status() async -> Status {
        var hasStoredToken = false
        var lastRenewed: Date?
        var storedRoot: String?
        do {
            hasStoredToken = try await Setting.value(for: Setting.googleDriveRefreshToken, on: db) != nil
            lastRenewed = try await Setting.value(for: Setting.googleDriveTokenRenewedAt, on: db)
                .flatMap { try? Date($0, strategy: .iso8601) }
            storedRoot = try await Setting.value(for: Setting.googleDriveRootFolderID, on: db)
        } catch {
            logger.warning("[Google Drive] Could not read the stored settings: \(error)")
        }

        var account: String?
        var folderName: String?
        var failure: String?
        var missing = false
        do {
            account = try await signedInAccount()
            if case .verify(let id) = Self.rootFolderPlan(storedID: storedRoot) {
                let found = try await fileResource(id: id)
                do {
                    _ = try Self.checkedRootFolder(id: id, named: rootFolderName, found: found)
                    folderName = found?.name
                } catch {
                    missing = true
                    throw error
                }
            }
        } catch {
            failure = "\(error)"
        }

        return Status(
            hasStoredToken: hasStoredToken, lastRenewed: lastRenewed,
            hasSeedToken: !seedRefreshToken.isEmpty, account: account,
            rootFolderID: Self.rootFolderPlan(storedID: storedRoot) == .create ? nil : storedRoot,
            rootFolderName: folderName, error: failure, rootFolderMissing: missing)
    }

    /// `about.get`: the authorising account, as an email address where Google gives one.
    private func signedInAccount() async throws -> String {
        struct About: Decodable {
            struct User: Decodable { let displayName: String?; let emailAddress: String? }
            let user: User
        }
        let response = try await get(
            "https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress)")
        try response.orThrow()
        let user = try response.decode(About.self).user
        return user.emailAddress ?? user.displayName ?? "an unnamed account"
    }

    // MARK: - HTTP

    private struct DriveResponse {
        let status: HTTPResponseStatus
        let headers: HTTPHeaders
        let body: Data

        var text: String { String(data: body, encoding: .utf8) ?? "<\(body.count) bytes>" }

        func orThrow() throws {
            guard !(200..<300).contains(Int(status.code)) else { return }
            if status == .unauthorized { throw GoogleDriveError.unauthorized }
            throw GoogleDriveError.http(status: status.code, body: text)
        }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            do {
                return try JSONDecoder().decode(type, from: body)
            } catch {
                throw GoogleDriveError.unexpectedBody(text)
            }
        }
    }

    /// A request to `url` carrying a current access token.
    private func authorised(_ url: String, method: HTTPMethod) async throws -> HTTPClientRequest {
        let token = try await validAccessToken()
        var request = HTTPClientRequest(url: url)
        request.method = method
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        return request
    }

    private func get(_ url: String) async throws -> DriveResponse {
        try await execute(try await authorised(url, method: .GET), timeout: .seconds(30))
    }

    private func execute(_ request: HTTPClientRequest, timeout: TimeAmount) async throws -> DriveResponse {
        let response = try await httpClient.execute(request, timeout: timeout)
        let buffer = try await response.body.collect(upTo: 8 * 1024 * 1024)
        return DriveResponse(status: response.status, headers: response.headers, body: Data(buffer: buffer))
    }
}

// MARK: - ArtifactDestination

extension GoogleDriveService: AuthorizableDestination {

    /// Also `ARTIFACT_DESTINATION`'s value, and the prefix of the settings kept for it.
    nonisolated var id: String { "google_drive" }

    nonisolated var displayName: String { "Google Drive" }

    /// Registered as an authorised redirect URI on the OAuth client in the Cloud console.
    nonisolated var callbackPath: String { "/google-drive-callback" }

    /// Google expires a refresh token that has gone unused for six months.
    nonisolated var credentialLifetime: TimeInterval? { 182 * 24 * 60 * 60 }

    nonisolated func authorizationURL(redirectURI: String, state: String) async -> String {
        Self.authorizationURL(clientID: clientID, redirectURI: redirectURI, state: state)
    }

    func publish(_ file: URL, forBranch branch: String) async throws -> PublishedLocation {
        let folderID = try await upload(file, forBranch: branch)
        return PublishedLocation(browseURL: URL(string: Self.folderURL(id: folderID)))
    }

    func connectionStatus() async -> ConnectionStatus {
        let status = await status()
        let configured = !(Environment.get("GOOGLE_CLIENT_ID") ?? "").isEmpty
            && !(Environment.get("GOOGLE_CLIENT_SECRET") ?? "").isEmpty

        let credential: String
        if let renewed = status.lastRenewed, let lifetime = credentialLifetime {
            let days = Int(renewed.addingTimeInterval(lifetime).timeIntervalSinceNow / 86400)
            credential = days > 0
                ? "Refresh token last used \(ConnectionsReport.relative(renewed)); expires in \(days) day(s) otherwise. Renewed automatically every \(RecurringSchedule.describe(DestinationKeepAlive.interval())), so it cannot expire while TNG is running."
                : "⚠ Refresh token last used \(ConnectionsReport.relative(renewed)) and has passed Google's six-month limit"
        } else if status.hasStoredToken {
            credential = "Refresh token stored; not renewed yet"
        } else if status.hasSeedToken {
            credential = "Using the GOOGLE_REFRESH_TOKEN from .env; nothing renewed yet"
        } else {
            credential = "No refresh token — TNG has never been authorised"
        }

        guard configured else {
            return ConnectionStatus(
                id: id, name: displayName, purpose: Self.purpose,
                state: .unconfigured, detail: nil, credential: credential,
                error: "GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET must be set before TNG can be authorised",
                authorizePath: nil,
                remedy: "Create an OAuth client in the Google Cloud console (§ Google Drive OAuth2 in the README) and put its ID and secret in .env.")
        }

        let detail: String?
        if let account = status.account {
            detail = status.rootFolderName.map { "Publishing into \($0) as \(account)" }
                ?? (status.rootFolderID == nil
                    ? "Signed in as \(account). The first publish creates \(rootFolderName) at the top of its My Drive."
                    : nil)
        } else {
            detail = nil
        }

        return ConnectionStatus(
            id: id, name: displayName, purpose: Self.purpose,
            state: status.error == nil ? .working : .failing,
            detail: detail,
            credential: credential,
            error: status.error,
            authorizePath: ConnectionsController.authorizePath,
            remedy: status.rootFolderMissing ? Self.missingRootRemedy : nil,
            link: status.rootFolderName == nil ? nil : status.rootFolderID.map(Self.folderURL(id:)))
    }

    private static let purpose =
        "Where the band's official binders are published, in a folder per year."

    private static let missingRootRemedy = """
        TNG will not make a replacement on its own, because the band shares the folder it \
        made, and a new one would be shared with nobody. Restore the folder from Drive's \
        trash if it is there. Otherwise delete the stored ID — sqlite3 \
        "$TNG_STATE_DIR/data/tng.sqlite" "DELETE FROM settings WHERE key = \
        'google_drive.root_folder_id'" — and the next publish makes a new folder, to be \
        shared again.
        """
}

// MARK: - GoogleDriveError

enum GoogleDriveError: Error, CustomStringConvertible {
    case noRefreshToken
    case refreshRejected(body: String)
    case unauthorized
    case tokenNotPersisted(String)
    /// The root folder TNG made, and recorded, is no longer there.
    case rootFolderMissing(id: String, name: String)
    case http(status: UInt, body: String)
    case unexpectedBody(String)

    var description: String {
        switch self {
        case .noRefreshToken:
            return "No Google Drive refresh token: authorise TNG from the Connections page on "
                + "the admin dashboard"
        case .refreshRejected(let body):
            return "Google rejected the refresh token — press Re-authorise Google Drive on the "
                + "Connections page: \(body)"
        case .unauthorized:
            return "Google rejected the access token"
        case .tokenNotPersisted(let detail):
            return "A Google Drive refresh token could not be stored, so it will be lost at "
                + "the next restart: \(detail)"
        case .rootFolderMissing(let id, let name):
            return "The Google Drive folder TNG publishes into, \(name) (\(id)), has been "
                + "deleted or moved to the trash"
        case .http(let status, let body):
            return "HTTP \(status) from Google Drive: \(body)"
        case .unexpectedBody(let body):
            return "Unexpected response body from Google Drive: \(body)"
        }
    }
}
