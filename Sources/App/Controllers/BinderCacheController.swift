import Fluent
import Vapor

// MARK: - BinderCacheController

/// The admin page for personal binder retention (#83).
///
/// Routes (admin-only):
///   - `GET /admin/binders`           — the retention period, and the binders on disk
///   - `PUT /admin/binders/retention` — change the period; JSON `{"days": 14}`
///
/// The change is a JSON request rather than a form post, like the dashboard's other
/// actions: a cross-site form cannot send one without a preflight.
struct BinderCacheController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped(AdminAuthMiddleware())
        admin.get("admin", "binders", use: page)
        admin.put("admin", "binders", "retention", use: setRetention)
    }

    /// What the page is rendered from.
    struct Context: Encodable {
        let appVersion: String
        let isAdmin: Bool
        let currentUser: String
        let retentionDays: Int
        /// `admin`, `environment` or `builtIn`.
        let retentionSource: BinderCache.Source
        let binderCount: Int
        /// The space the binders take, for people: "3.2 MB".
        let binderSize: String
        let directory: String
    }

    // MARK: - The page

    @Sendable
    func page(_ req: Request) async throws -> View {
        let retention = try await BinderCache.retention(on: req.db)
        let directory = req.application.binderService.personalBindersDirectory
        let usage = try BinderCache.usage(of: directory)

        return try await req.view.render("admin/binders", Context(
            appVersion: AppVersion.current,
            isAdmin: true,
            currentUser: req.authenticatedUser?.displayName ?? req.authenticatedUser?.slackUserId ?? "",
            retentionDays: retention.days,
            retentionSource: retention.source,
            binderCount: usage.count,
            binderSize: ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file),
            directory: directory.path
        ))
    }

    // MARK: - Changing the period

    struct RetentionUpdate: Content {
        let days: Int
    }

    /// `PUT /admin/binders/retention` — stores the period, which then overrides
    /// `BINDER_RETENTION_DAYS`. Binders already built keep the expiry they were given.
    @Sendable
    func setRetention(_ req: Request) async throws -> RetentionUpdate {
        let update = try req.content.decode(RetentionUpdate.self)
        guard update.days >= 1 else {
            throw Abort(.unprocessableEntity, reason: "The retention period must be at least 1 day.")
        }

        try await Setting.set(Setting.binderRetentionDays, to: String(update.days), on: req.db)
        let user = req.authenticatedUser?.displayName ?? req.authenticatedUser?.slackUserId ?? "unknown"
        req.logger.notice("[admin] \(user) set binder retention to \(update.days) day(s)")
        return update
    }
}
