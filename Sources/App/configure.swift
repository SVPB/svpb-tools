import AsyncHTTPClient
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
///
/// `BOX_REFRESH_TOKEN` is deliberately *not* here. It is the one credential the server
/// can obtain for itself — from `/admin/connections`, which a deployment has to be able
/// to boot far enough to reach. Refusing to start without one would mean a fresh
/// deployment could never be authorised at all.
private let requiredEnvironmentVariables: [String] = [
    "GITHUB_WEBHOOK_SECRET",
    "SVPB_MUSIC_REPO_URL",
    "BOX_CLIENT_ID",
    "BOX_CLIENT_SECRET",
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

/// The line `configure` logs at boot: which Vapor environment the server runs as, and the
/// log level in force (#95). The published image sets `VAPOR_ENV=production` and
/// `LOG_LEVEL=info`; `swift run` and `dev.sh` stay `development`.
func bootSummary(environment: Environment, logLevel: Logger.Level) -> String {
    "Environment: \(environment.name), log level: \(logLevel)"
}

public func configure(_ app: Application) async throws {
    // ── Register commands ───────────────────────────────────────────────────
    app.asyncCommands.use(BoxAuthCommand(), as: BoxAuthCommand.name)

    // In box-auth mode, skip full configuration — the command only needs the
    // event loop and its own minimal HTTP setup.
    if isBoxAuthMode { return }

    // ── Environment ────────────────────────────────────────────────────────
    // First, so it heads `docker compose logs` even when configuration fails below (#95).
    app.logger.notice("\(bootSummary(environment: app.environment, logLevel: app.logger.logLevel))")

    // ── Environment variable validation ────────────────────────────────────
    if app.environment != .testing {
        for key in requiredEnvironmentVariables {
            guard Environment.get(key) != nil else {
                throw ConfigurationError.missingEnvironmentVariable(key)
            }
        }
    }

    // ── Static file serving ────────────────────────────────────────────────
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // ── Sessions ───────────────────────────────────────────────────────────
    // Fluent-backed sessions persist across server restarts.
    app.sessions.use(.fluent)
    // A sign-in ends after SESSION_IDLE_DAYS unused or SESSION_MAX_DAYS in all, and the
    // cookie lasts as long as the idle limit (#93). The cookie is HttpOnly, and Secure
    // unless DOMAIN names this machine (#94). Set before the middleware is made, since it
    // copies the configuration.
    let sessionPolicy = try SessionExpiry.Policy.load(from: Environment.get)
    app.sessionExpiryPolicy = sessionPolicy
    app.sessions.configuration = SessionCookie.sessionsConfiguration(
        policy: sessionPolicy,
        secure: SessionCookie.isSecure(domain: Environment.get("DOMAIN"))
    )
    app.middleware.use(app.sessions.middleware)
    // Immediately after, so its stamps are in what the sessions middleware stores.
    app.middleware.use(SessionExpiryMiddleware())
    // Inside the sessions middleware, so an empty session — including one just emptied
    // because it expired — is discarded before it would be stored (#92).
    app.middleware.use(EmptySessionMiddleware())

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
    //   7. BinderDefinition — FK → Branch
    //   8. Setting        — no FKs
    //   9. BoxUpload      — FK → Branch; renamed BinderUpload by RenameBoxUploads
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
    app.migrations.add(CreateBinderDefinition())
    app.migrations.add(AddSubtitleToTune())
    // Phase 1 (C5): runtime state that outlives the process.
    app.migrations.add(CreateSetting())
    app.migrations.add(CreateBoxUpload())
    app.migrations.add(AddExpiresAtToBinderRequest())
    // Stamps the sessions signed in before #93 with the deploy time; needs SessionRecord.
    app.migrations.add(StampExistingSessions())
    // box_uploads → binder_uploads: nothing in the record is specific to Box (#85).
    app.migrations.add(RenameBoxUploads())
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
    app.gitService = gitService

    let boxService = BoxService(
        clientID:     Environment.get("BOX_CLIENT_ID")     ?? "",
        clientSecret: Environment.get("BOX_CLIENT_SECRET") ?? "",
        rootFolderID: Environment.get("BOX_FOLDER_ID")     ?? "",
        refreshToken: Environment.get("BOX_REFRESH_TOKEN") ?? "",
        // The environment seeds the refresh token; the database holds the rotated one,
        // so a restart does not reach for a token Box has already retired.
        db:           app.db,
        httpClient:   httpClient,
        logger:       app.logger
    )
    app.boxService = boxService
    // Where binders are published. The credential code above still talks to
    // `boxService` directly; the build only knows it as a destination.
    app.artifactDestination = boxService

    let slackService = SlackService(
        botToken:   Environment.get("SLACK_BOT_TOKEN")   ?? "",
        webhookURL: Environment.get("SLACK_WEBHOOK_URL") ?? "",
        httpClient: httpClient,
        logger:     app.logger
    )
    app.slackService = slackService

    let binderService = BinderService(musicWorkspacePath: musicWorkspacePath)
    app.binderService = binderService

    // Box's refresh token expires after 60 days of disuse, and a build is the only thing
    // that would otherwise use it. Renew it on a timer so a quiet season cannot kill it.
    app.lifecycle.use(BoxTokenKeepAlive())

    // The database is the one thing TNG cannot regenerate; copy it off the server nightly.
    app.lifecycle.use(DatabaseBackup())

    // Personal binders are kept for a fixed number of days, then deleted (#83).
    app.lifecycle.use(BinderCache())

    // Sessions that can no longer sign anyone in are deleted, by #93's expiry rule (#90).
    app.lifecycle.use(SessionSweeper())

    app.buildService = BuildService(
        gitService:         gitService,
        destination:        app.artifactDestination,
        slackService:       slackService,
        binderService:      binderService,
        musicWorkspacePath: musicWorkspacePath
    )
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
