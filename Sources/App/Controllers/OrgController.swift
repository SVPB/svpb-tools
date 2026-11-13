import Fluent
import Vapor

// MARK: - OrgController

/// The organisation's name and artwork: the admin page that sets them, and the routes that
/// serve the artwork (#89).
///
/// Admin routes:
///   - `GET    /admin/org`                — the names and artwork, and where each comes from
///   - `PUT    /admin/org/names`          — JSON `{"name": "…", "shortName": "…"}`; a blank
///                                          name clears the override, back to `.env`
///   - `PUT    /admin/org/artwork/:slot`  — the image itself as the body
///   - `DELETE /admin/org/artwork/:slot`  — back to the built-in image
///
/// Public routes, each the upload when there is one and the built-in image otherwise:
///   - `GET /favicon.ico`, `GET /favicon.svg` — the favicon slot
///   - `GET /apple-touch-icon.png`            — the touch-icon slot
///   - `GET /img/logo`                        — the logo slot
///
/// Changes are JSON or raw-body `PUT`s and `DELETE`s, like the dashboard's other actions:
/// a cross-site form cannot send one without a preflight.
struct OrgController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        routes.get("favicon.ico") { try await serve($0, .favicon, fallback: \.faviconICO, as: .ico) }
        routes.get("favicon.svg") { try await serve($0, .favicon, fallback: \.faviconSVG, as: .svg) }
        routes.get("apple-touch-icon.png") { try await serve($0, .touchIcon, fallback: \.touchIconPNG, as: .png) }
        routes.get("img", "logo") { try await serve($0, .logo, fallback: \.logoSVG, as: .svg) }

        let admin = routes.grouped(AdminAuthMiddleware())
        admin.get("admin", "org", use: page)
        admin.put("admin", "org", "names", use: setNames)
        // Collected up to twice the limit, so an upload a little over it gets a reason
        // rather than a bare 413.
        admin.on(.PUT, "admin", "org", "artwork", ":slot",
                 body: .collect(maxSize: ByteCount(value: 2 * OrgArtwork.maxBytes)), use: upload)
        admin.delete("admin", "org", "artwork", ":slot", use: removeArtwork)
    }

    // MARK: - Serving the artwork

    /// Headers on every artwork response.
    ///
    /// The CSP matters for an uploaded SVG opened directly: it allows no script and no
    /// loads, and `sandbox` puts the document in an opaque origin, so even script that
    /// somehow ran could not reach TNG's cookies or pages. It is harmless on the rest.
    /// `no-cache` with an ETag means a browser asks each time, and is told "unchanged"
    /// cheaply, so a new upload shows up at once.
    static let securityHeaders: [(HTTPHeaders.Name, String)] = [
        (HTTPHeaders.Name("Content-Security-Policy"), "default-src 'none'; style-src 'unsafe-inline'; sandbox"),
        (HTTPHeaders.Name("X-Content-Type-Options"), "nosniff"),
        (.cacheControl, "no-cache"),
    ]

    private func serve(
        _ req: Request,
        _ slot: OrgAsset.Slot,
        fallback: KeyPath<OrgArtwork.Defaults, Data>,
        as defaultFormat: ArtworkFormat
    ) async throws -> Response {
        let bytes: Data
        let contentType: String
        let etag: String
        if let asset = try await OrgAsset.find(slot, on: req.db) {
            bytes = asset.bytes
            contentType = asset.contentType
            let stamp = Int((asset.updatedAt ?? .distantPast).timeIntervalSince1970 * 1000)
            etag = "\"\(slot.rawValue)-\(stamp)-\(asset.bytes.count)\""
        } else {
            bytes = req.application.defaultArtwork[keyPath: fallback]
            contentType = defaultFormat.contentType
            etag = "\"default-\(slot.rawValue)-\(defaultFormat.rawValue)-\(AppVersion.current)\""
        }

        var headers = HTTPHeaders()
        for (name, value) in Self.securityHeaders {
            headers.replaceOrAdd(name: name, value: value)
        }
        headers.replaceOrAdd(name: .eTag, value: etag)
        if req.headers.first(name: .ifNoneMatch) == etag {
            return Response(status: .notModified, headers: headers)
        }
        headers.replaceOrAdd(name: .contentType, value: contentType)
        return Response(status: .ok, headers: headers, body: .init(data: bytes))
    }

    // MARK: - The page

    struct SlotRow: Encodable {
        let slot: String
        let label: String
        let purpose: String
        /// Where the image is served, for the preview.
        let url: String
        /// "SVG or PNG", for the hint under the file picker.
        let accepts: String
        /// The `accept` attribute of the file picker.
        let acceptAttribute: String
        let uploaded: Bool
        /// When the upload was stored, ISO 8601, for the page's script to show locally.
        let updatedISO: String?
        /// What the upload was recognised as: "SVG".
        let format: String?
    }

    struct Context: Encodable {
        let appVersion: String
        let isAdmin: Bool
        let currentUser: String
        /// The admin overrides, empty when there is none: what the inputs hold.
        let nameOverride: String
        let shortNameOverride: String
        /// What applies without an override, from `.env`: the inputs' placeholders.
        let nameFromEnvironment: String?
        let shortNameFromEnvironment: String?
        /// `admin`, `environment` or `builtIn`.
        let nameSource: Setting.Source
        let shortNameSource: Setting.Source
        let siteName: String
        let subtitle: String
        let slots: [SlotRow]
        let maxBytes: String
    }

    @Sendable
    func page(_ req: Request) async throws -> View {
        let resolved = try await OrgProfile.resolve(on: req.db)
        let iso = ISO8601DateFormatter()

        var rows: [SlotRow] = []
        for slot in OrgAsset.Slot.allCases {
            let asset = try await OrgAsset.find(slot, on: req.db)
            let formats = OrgArtwork.formats(for: slot)
            rows.append(SlotRow(
                slot: slot.rawValue,
                label: Self.label(slot),
                purpose: Self.purpose(slot),
                url: Self.previewPath(slot),
                accepts: formats.map(\.label).joined(separator: " or ")
                    + (slot == .touchIcon ? ", \(OrgArtwork.touchIconSide)×\(OrgArtwork.touchIconSide)" : ""),
                acceptAttribute: formats.map { ".\($0.rawValue),\($0.contentType)" }.joined(separator: ","),
                uploaded: asset != nil,
                updatedISO: asset?.updatedAt.map { iso.string(from: $0) },
                format: asset.flatMap { a in ArtworkFormat.allCases.first { $0.contentType == a.contentType }?.label }
            ))
        }

        return try await req.view.render("admin/org", Context(
            appVersion: AppVersion.current,
            isAdmin: true,
            currentUser: req.authenticatedUser?.displayName ?? req.authenticatedUser?.slackUserId ?? "",
            nameOverride: try await Setting.value(for: Setting.orgName, on: req.db) ?? "",
            shortNameOverride: try await Setting.value(for: Setting.orgShortName, on: req.db) ?? "",
            nameFromEnvironment: Setting.nonBlank(Environment.get(OrgProfile.nameVariable)),
            shortNameFromEnvironment: Setting.nonBlank(Environment.get(OrgProfile.shortNameVariable)),
            nameSource: resolved.nameSource,
            shortNameSource: resolved.shortNameSource,
            siteName: resolved.names.siteName,
            subtitle: resolved.names.subtitle,
            slots: rows,
            maxBytes: "1 MB"
        ))
    }

    static func label(_ slot: OrgAsset.Slot) -> String {
        switch slot {
        case .logo:      "Header logo"
        case .favicon:   "Favicon"
        case .touchIcon: "Touch icon"
        }
    }

    static func purpose(_ slot: OrgAsset.Slot) -> String {
        switch slot {
        case .logo:      "Beside the name at the top of every page, on the dark header."
        case .favicon:   "The icon in browser tabs and bookmarks."
        case .touchIcon: "The icon iPhones and iPads use for a home-screen bookmark."
        }
    }

    static func previewPath(_ slot: OrgAsset.Slot) -> String {
        switch slot {
        case .logo:      "/img/logo"
        case .favicon:   "/favicon.svg"
        case .touchIcon: "/apple-touch-icon.png"
        }
    }

    // MARK: - Names

    struct NamesUpdate: Content {
        let name: String?
        let shortName: String?
    }

    /// `PUT /admin/org/names` — stores each name as an override of `.env`, or clears the
    /// override when it is blank, and puts the result in force at once.
    @Sendable
    func setNames(_ req: Request) async throws -> HTTPStatus {
        let update = try req.content.decode(NamesUpdate.self)
        for (key, value) in [(Setting.orgName, update.name), (Setting.orgShortName, update.shortName)] {
            if let value = Setting.nonBlank(value) {
                try await Setting.set(key, to: value, on: req.db)
            } else {
                try await Setting.clear(key, on: req.db)
            }
        }
        try await req.application.orgProfile.reload(on: req.db)

        let names = req.application.orgProfile.names
        req.logger.notice("""
            [admin] \(Self.actor(req)) set the organisation's names: \
            name \(names.name.map { "'\($0)'" } ?? "unset"), \
            short name \(names.shortName.map { "'\($0)'" } ?? "unset")
            """)
        return .noContent
    }

    // MARK: - Artwork

    private func slot(_ req: Request) throws -> OrgAsset.Slot {
        guard let raw = req.parameters.get("slot"), let slot = OrgAsset.Slot(rawValue: raw) else {
            throw Abort(.notFound, reason: "There is no artwork slot by that name.")
        }
        return slot
    }

    /// `PUT /admin/org/artwork/:slot` — the image is the request body. Recognised by its
    /// content, checked, and stored exactly as uploaded.
    @Sendable
    func upload(_ req: Request) async throws -> HTTPStatus {
        let slot = try slot(req)
        guard let buffer = req.body.data else {
            throw Abort(.unprocessableEntity, reason: "No file was sent.")
        }
        let data = Data(buffer: buffer)

        let format: ArtworkFormat
        do {
            format = try OrgArtwork.check(data, for: slot)
        } catch let rejection as OrgArtwork.Rejection {
            throw Abort(.unprocessableEntity, reason: rejection.reason)
        } catch let rejection as SVGValidator.Rejection {
            throw Abort(.unprocessableEntity, reason: rejection.reason)
        }

        try await OrgAsset.store(data, contentType: format.contentType, in: slot, on: req.db)
        req.logger.notice("[admin] \(Self.actor(req)) uploaded a \(format.label) \(slot.rawValue) (\(data.count) bytes)")
        return .noContent
    }

    /// `DELETE /admin/org/artwork/:slot` — removes the upload; the built-in image is served
    /// again.
    @Sendable
    func removeArtwork(_ req: Request) async throws -> HTTPStatus {
        let slot = try slot(req)
        try await OrgAsset.find(slot, on: req.db)?.delete(on: req.db)
        req.logger.notice("[admin] \(Self.actor(req)) removed the uploaded \(slot.rawValue)")
        return .noContent
    }

    private static func actor(_ req: Request) -> String {
        req.authenticatedUser?.displayName ?? req.authenticatedUser?.slackUserId ?? "unknown"
    }
}
