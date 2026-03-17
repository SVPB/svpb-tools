import Fluent
import Vapor

/// Handles all `/admin/*` routes.
///
/// HTML routes (Leaf-rendered):
///   `GET  /admin`              — build history dashboard
///   `GET  /admin/login`        — unauthenticated landing page
///   `GET  /admin/builds/{id}`  — full build log
///   `POST /admin/logout`       — destroy session and redirect
///
/// JSON API routes (admin-only, all require a valid session):
///   `GET    /admin/users`          — list all users
///   `POST   /admin/users`          — create a new user
///   `PATCH  /admin/users/:id`      — update a user's role
///   `DELETE /admin/users/:id`      — delete a user
struct AdminController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        // Unauthenticated pages — no middleware.
        routes.get("admin", "login", use: loginPage)

        // Authenticated pages and APIs — guarded by AdminAuthMiddleware.
        // Sessions middleware is applied globally in configure.swift.
        let admin = routes.grouped(AdminAuthMiddleware())
        admin.get("admin", use: dashboard)
        admin.get("admin", "builds", ":buildId", use: buildDetail)
        admin.post("admin", "logout", use: logout)

        // User management API.
        let users = admin.grouped("admin", "users")
        users.get(use: listUsers)
        users.post(use: createUser)
        users.patch(":userId", use: updateUser)
        users.delete(":userId", use: deleteUser)
    }

    // MARK: - Unauthenticated pages

    /// Landing page shown when a user navigates to `/admin` without a session.
    /// Explains how to request a magic-link via Slack.
    @Sendable
    func loginPage(_ req: Request) async throws -> View {
        return try await req.view.render("admin/login", ["appVersion": AppVersion.current])
    }

    // MARK: - Dashboard

    @Sendable
    func dashboard(_ req: Request) async throws -> View {
        let builds = try await Build.query(on: req.db)
            .sort(\.$triggered, .descending)
            .limit(50)
            .all()

        let branches = try await Branch.query(on: req.db).all()

        struct DashboardContext: Encodable {
            struct BuildRow: Encodable {
                let id: String
                let branch: String
                let triggeredISO: String
                let status: String
                let fileCount: Int
            }
            let appVersion: String
            let builds: [BuildRow]
            let branchNames: [String]
            let currentUser: String
        }

        let isoFormatter = ISO8601DateFormatter()
        let buildRows = builds.map { b in
            DashboardContext.BuildRow(
                id: b.id?.uuidString ?? "",
                branch: b.$branch.id,
                triggeredISO: b.triggered.map { isoFormatter.string(from: $0) } ?? "—",
                status: b.status.rawValue,
                fileCount: b.files.count
            )
        }

        let ctx = DashboardContext(
            appVersion: AppVersion.current,
            builds: buildRows,
            branchNames: branches.map(\.name),
            currentUser: req.authenticatedUser?.slackUserId ?? ""
        )
        return try await req.view.render("admin/index", ctx)
    }

    // MARK: - Build detail

    @Sendable
    func buildDetail(_ req: Request) async throws -> View {
        guard let idString = req.parameters.get("buildId"),
              let uuid = UUID(uuidString: idString),
              let build = try await Build.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }

        struct DetailContext: Encodable {
            let appVersion: String
            let buildId: String
            let branch: String
            let triggeredISO: String
            let status: String
            let commitSha: String
            let files: [String]
            let log: String
        }

        let isoFormatter = ISO8601DateFormatter()
        let ctx = DetailContext(
            appVersion: AppVersion.current,
            buildId: build.id?.uuidString ?? "",
            branch: build.$branch.id,
            triggeredISO: build.triggered.map { isoFormatter.string(from: $0) } ?? "—",
            status: build.status.rawValue,
            commitSha: build.commitSha ?? "—",
            files: build.files,
            log: build.log ?? "(no log)"
        )
        return try await req.view.render("admin/build-detail", ctx)
    }

    // MARK: - Logout

    @Sendable
    func logout(_ req: Request) async throws -> Response {
        req.session.destroy()
        return req.redirect(to: "/admin/login")
    }

    // MARK: - User management

    /// `GET /admin/users` — HTML page listing all users with role and delete controls.
    @Sendable
    func listUsers(_ req: Request) async throws -> View {
        let users = try await User.query(on: req.db)
            .sort(\.$createdAt, .ascending)
            .all()

        struct UserRow: Encodable {
            let id: String
            let slackUserId: String
            let displayName: String
            let role: String
            let createdAt: String
            let lastLoginAt: String
            let isSelf: Bool
        }

        struct UsersContext: Encodable {
            let appVersion: String
            let currentUser: String
            let users: [UserRow]
        }

        let isoFormatter = ISO8601DateFormatter()
        let selfId = req.authenticatedUser?.id?.uuidString ?? ""

        let rows = try users.map { u in
            UserRow(
                id: try u.requireID().uuidString,
                slackUserId: u.slackUserId,
                displayName: u.displayName ?? u.slackUserId,
                role: u.role.rawValue,
                createdAt: u.createdAt.map { isoFormatter.string(from: $0) } ?? "—",
                lastLoginAt: u.lastLoginAt.map { isoFormatter.string(from: $0) } ?? "never",
                isSelf: try u.requireID().uuidString == selfId
            )
        }

        let ctx = UsersContext(
            appVersion: AppVersion.current,
            currentUser: req.authenticatedUser?.slackUserId ?? "",
            users: rows
        )
        return try await req.view.render("admin/users", ctx)
    }

    @Sendable
    func createUser(_ req: Request) async throws -> Response {
        let body = try req.content.decode(UserCreateRequest.self)

        // Prevent duplicate Slack user IDs.
        let existing = try await User.query(on: req.db)
            .filter(\.$slackUserId == body.slackUserId)
            .first()
        guard existing == nil else {
            throw Abort(.conflict, reason: "User with Slack ID '\(body.slackUserId)' already exists.")
        }

        let user = User(slackUserId: body.slackUserId, role: body.role)
        try await user.save(on: req.db)

        let dto = try UserDTO(from: user)
        return try await dto.encodeResponse(status: .created, for: req)
    }

    @Sendable
    func updateUser(_ req: Request) async throws -> UserDTO {
        guard let idString = req.parameters.get("userId"),
              let uuid = UUID(uuidString: idString),
              let user = try await User.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Prevent an admin from demoting themselves.
        if let self_ = req.authenticatedUser, (try? self_.requireID()) == uuid,
           user.role == .admin {
            let update = try req.content.decode(UserRoleUpdate.self)
            if update.role != .admin {
                throw Abort(.forbidden, reason: "You cannot remove your own admin role.")
            }
        }

        let update = try req.content.decode(UserRoleUpdate.self)
        user.role = update.role
        try await user.save(on: req.db)
        return try UserDTO(from: user)
    }

    @Sendable
    func deleteUser(_ req: Request) async throws -> HTTPStatus {
        guard let idString = req.parameters.get("userId"),
              let uuid = UUID(uuidString: idString),
              let user = try await User.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Prevent self-deletion.
        if let self_ = req.authenticatedUser, (try? self_.requireID()) == uuid {
            throw Abort(.forbidden, reason: "You cannot delete your own account.")
        }

        try await user.delete(on: req.db)
        return .noContent
    }
}
