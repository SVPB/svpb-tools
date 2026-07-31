import AsyncHTTPClient
import CeolKitSVGRenderer
import Fluent
import FluentSQLiteDriver
import Leaf
import Vapor

/// Thrown at startup when a required environment variable is absent.
struct ConfigurationError: Error, CustomStringConvertible {
    let description: String

    static func missingEnvironmentVariable(_ key: String) -> ConfigurationError {
        ConfigurationError(description: "Required environment variable '\(key)' is not set.")
    }
}

/// All environment variables the server depends on.
///
/// Variables are validated at startup so that misconfiguration is caught
/// immediately rather than surfacing as a runtime failure hours later.
/// In the `.testing` environment the check is skipped so unit tests can
/// run without a full `.env` file.
private let requiredEnvironmentVariables: [String] = [
    "GITHUB_WEBHOOK_SECRET",
    "SVPB_MUSIC_REPO_URL",
    "BOX_CLIENT_ID",
    "BOX_CLIENT_SECRET",
    "BOX_REFRESH_TOKEN",
    "BOX_FOLDER_ID",
    "SLACK_BOT_TOKEN",
    "SLACK_SIGNING_SECRET",
    "SLACK_WEBHOOK_URL",
    "INITIAL_ADMIN_SLACK_USER_ID",
]

/// Returns `true` when the process was invoked as `TNG box-auth …`
private var isBoxAuthMode: Bool {
    CommandLine.arguments.contains(BoxAuthCommand.name)
}

public func configure(_ app: Application) async throws {
    // ── Register commands ───────────────────────────────────────────────────
    app.asyncCommands.use(BoxAuthCommand(), as: BoxAuthCommand.name)

    // In box-auth mode, skip full configuration — the command only needs the
    // event loop and its own minimal HTTP setup.
    if isBoxAuthMode { return }

    // ── Environment variable validation ────────────────────────────────────
    if app.environment != .testing {
        for key in requiredEnvironmentVariables {
            guard Environment.get(key) != nil else {
                throw ConfigurationError.missingEnvironmentVariable(key)
            }
        }
    }

    // On Apple platforms SVGPDFKit rasterises in-process through CoreGraphics,
    // which resolves font-family against process-registered fonts rather than
    // the SVG's embedded @font-face data, so the bundled faces must be
    // registered here.
    //
    _ = CeolKitFonts.register()

    // ── Static file serving ────────────────────────────────────────────────
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // ── Sessions ───────────────────────────────────────────────────────────
    // Fluent-backed sessions persist across server restarts.
    app.sessions.use(.fluent)
    app.middleware.use(app.sessions.middleware)

    // ── Templating ─────────────────────────────────────────────────────────
    app.views.use(.leaf)

    // ── Database ───────────────────────────────────────────────────────────
    // Tests get a private in-memory database: running them against the
    // developer's real data/tng.sqlite made assertions depend on whatever
    // branches happened to be sitting in it, and CI has no data/ directory
    // for SQLite to open in the first place.
    if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        let dbPath = Environment.get("DATABASE_PATH") ?? "data/tng.sqlite"
        app.databases.use(.sqlite(.file(dbPath)), as: .sqlite)
    }

    // ── Migrations ─────────────────────────────────────────────────────────
    addMigrations(app)
    try await app.autoMigrate()

    // ── Services ───────────────────────────────────────────────────────────
    initServices(app)

    // ── Routes ─────────────────────────────────────────────────────────────
    try routes(app)

    // ── CORS ────────────────────────────────────────────────────────────────
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .originBased,
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [
            .accept, .authorization, .contentType, .origin,
            .xRequestedWith, .userAgent, .accessControlAllowOrigin,
        ]
    )
    app.middleware.use(CORSMiddleware(configuration: corsConfiguration), at: .beginning)

    // ── Initial admin bootstrap ─────────────────────────────────────────────
    // On first startup (empty User table), create an admin account for the
    // Slack user ID specified by INITIAL_ADMIN_SLACK_USER_ID.
    if app.environment != .testing {
        try await bootstrapAdminUser(app)
    }
}

// MARK: - Migrations

private func addMigrations(_ app: Application) {
    // Migrations must be registered in dependency order:
    //   1. Branch, User  — no external FKs
    //   2. Tune          — FK → Branch
    //   3. Part          — FK → Tune (cascade delete)
    //   4. Build         — FK → Branch
    //   5. BinderRequest — no external FKs
    //   6. LoginToken    — no FK (Slack user ID stored as plain TEXT)
    app.migrations.add(SessionRecord.migration)
    app.migrations.add(CreateBranch())
    app.migrations.add(CreateUser())
    app.migrations.add(CreateTune())
    app.migrations.add(CreatePart())
    app.migrations.add(CreateBuild())
    app.migrations.add(CreateBinderRequest())
    app.migrations.add(CreateLoginToken())
    // Phase 2
    app.migrations.add(AddSvgPathsToPart())
}

// MARK: - Service initialisation

private func initServices(_ app: Application) {
    // Shared HTTP client — shutdown is handled by HTTPClientLifecycleHandler.
    let httpClient = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup))
    app.sharedHTTPClient = httpClient
    app.lifecycle.use(HTTPClientLifecycleHandler())

    let musicWorkspacePath = Environment.get("MUSIC_WORKSPACE_PATH") ?? "./music"

    let gitService = GitService(
        repoURL: Environment.get("SVPB_MUSIC_REPO_URL") ?? "",
        workspaceBase: URL(fileURLWithPath: musicWorkspacePath, isDirectory: true)
    )

    let boxService = BoxService(
        clientID:     Environment.get("BOX_CLIENT_ID")     ?? "",
        clientSecret: Environment.get("BOX_CLIENT_SECRET") ?? "",
        rootFolderID: Environment.get("BOX_FOLDER_ID")     ?? "",
        refreshToken: Environment.get("BOX_REFRESH_TOKEN") ?? "",
        httpClient:   httpClient,
        logger:       app.logger
    )
    app.boxService = boxService

    let slackService = SlackService(
        botToken:   Environment.get("SLACK_BOT_TOKEN")   ?? "",
        webhookURL: Environment.get("SLACK_WEBHOOK_URL") ?? "",
        httpClient: httpClient,
        logger:     app.logger
    )
    app.slackService = slackService

    app.buildService = BuildService(
        gitService:         gitService,
        boxService:         boxService,
        slackService:       slackService,
        musicWorkspacePath: musicWorkspacePath
    )

    app.binderService = BinderService(musicWorkspacePath: musicWorkspacePath)
}

// MARK: - Admin bootstrap

/// Creates an admin `User` record for `INITIAL_ADMIN_SLACK_USER_ID` if the
/// `users` table is empty.  This seeds the first admin on a fresh deployment
/// without requiring any database tooling.
private func bootstrapAdminUser(_ app: Application) async throws {
    let count = try await User.query(on: app.db).count()
    guard count == 0 else { return }

    guard let slackUserId = Environment.get("INITIAL_ADMIN_SLACK_USER_ID") else { return }

    let admin = User(slackUserId: slackUserId, role: .admin)
    try await admin.save(on: app.db)
    app.logger.notice("[bootstrap] Created initial admin user for Slack ID '\(slackUserId)'")
}
