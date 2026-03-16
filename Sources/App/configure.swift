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
    "SLACK_WEBHOOK_URL",
    "ADMIN_PASSWORD",
]

public func configure(_ app: Application) async throws {
    // ── Environment variable validation ────────────────────────────────────
    if app.environment != .testing {
        for key in requiredEnvironmentVariables {
            guard Environment.get(key) != nil else {
                throw ConfigurationError.missingEnvironmentVariable(key)
            }
        }
    }

    // MARK: serve static files
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // ── Templating ─────────────────────────────────────────────────────────
    app.views.use(.leaf)

    // ── Database ───────────────────────────────────────────────────────────
    let dbPath = Environment.get("DATABASE_PATH") ?? "data/tng.sqlite"
    app.databases.use(.sqlite(.file(dbPath)), as: .sqlite)

    // MARK: migrations
    addMigrations(app)

    // ── Routes ─────────────────────────────────────────────────────────────
    try routes(app)

    // MARK: CORS
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .originBased,
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [
            .accept, .authorization, .contentType, .origin,
            .xRequestedWith, .userAgent, .accessControlAllowOrigin,
        ]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    // cors middleware should come before default error middleware using `at: .beginning`
    app.middleware.use(cors, at: .beginning)
}

private func addMigrations(_ app: Application) {
}
