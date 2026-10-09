import Foundation
import Vapor

// MARK: - ConnectionsReport

/// Gathers the state of every remote service TNG depends on.
///
/// Each service is asked the same question — can you be reached with what we hold? — and
/// answers in the same shape, so the page listing them needs to know nothing about Box,
/// Slack or git. Adding a service is a matter of writing one more `status(…)` here.
///
/// The probes run concurrently: three round trips to three different companies, and an
/// operator who has come to this page is already having a bad day.
enum ConnectionsReport {

    /// Every connection, in the order they matter to a build: where the music comes from,
    /// where the binders go, who gets told.
    static func gather(on app: Application) async -> [ConnectionStatus] {
        async let github = githubStatus(app)
        async let box = boxStatus(app)
        async let slack = slackStatus(app)
        async let backup = backupStatus(app)
        return await [github, box, slack, backup]
    }

    // MARK: - GitHub

    private static func githubStatus(_ app: Application) async -> ConnectionStatus {
        let hasSecret = !(Environment.get("GITHUB_WEBHOOK_SECRET") ?? "").isEmpty
        let repoURL = Environment.get("SVPB_MUSIC_REPO_URL") ?? ""
        // The webhook secret cannot be tested from here — it is only exercised when GitHub
        // signs a delivery — so it is reported as configuration, next to a probe that can.
        let credential = hasSecret
            ? "Webhook secret set; repository read with the URL's own credentials"
            : "⚠ GITHUB_WEBHOOK_SECRET is not set: pushes cannot be verified"
        let remedy = """
            Set SVPB_MUSIC_REPO_URL and GITHUB_WEBHOOK_SECRET in .env. The secret must match \
            the one in the repository's webhook settings on GitHub; generate one with \
            `openssl rand -hex 32`.
            """

        guard !repoURL.isEmpty else {
            return ConnectionStatus(
                id: "github", name: "GitHub", purpose: githubPurpose,
                state: .unconfigured, detail: nil, credential: credential,
                error: "SVPB_MUSIC_REPO_URL is not set",
                authorizePath: nil, remedy: remedy)
        }

        let service = app.gitService
        do {
            let branches = try await service.probeRemote()
            return ConnectionStatus(
                id: "github", name: "GitHub", purpose: githubPurpose,
                state: hasSecret ? .working : .failing,
                detail: "\(service.displayRepoURL) — \(branches) branch(es)",
                credential: credential,
                error: hasSecret ? nil : "The repository is readable, but a push cannot be verified without the webhook secret.",
                authorizePath: nil, remedy: remedy)
        } catch {
            return ConnectionStatus(
                id: "github", name: "GitHub", purpose: githubPurpose,
                state: .failing, detail: service.displayRepoURL, credential: credential,
                error: "\(error)", authorizePath: nil, remedy: remedy)
        }
    }

    private static let githubPurpose =
        "Where the music comes from. A push here starts a build."

    // MARK: - Box

    private static func boxStatus(_ app: Application) async -> ConnectionStatus {
        let status = await app.boxService.status()
        let configured = !(Environment.get("BOX_CLIENT_ID") ?? "").isEmpty
            && !(Environment.get("BOX_CLIENT_SECRET") ?? "").isEmpty

        let renewal = " Renewed automatically every "
            + ConnectionsReport.renewalInterval + ", so it cannot expire while TNG is running."

        let credential: String
        if let rotated = status.lastRotated {
            let expires = rotated.addingTimeInterval(ConnectionStatus.boxTokenLifetime)
            let days = Int(expires.timeIntervalSinceNow / 86400)
            credential = days > 0
                ? "Refresh token last renewed \(Self.relative(rotated)); expires in \(days) day(s) otherwise." + renewal
                : "⚠ Refresh token last renewed \(Self.relative(rotated)) and has passed its 60-day expiry"
        } else if status.hasSeedToken {
            credential = "Using the BOX_REFRESH_TOKEN from .env; nothing renewed yet"
        } else {
            credential = "No refresh token — TNG has never been authorised"
        }

        guard configured else {
            return ConnectionStatus(
                id: "box", name: "Box", purpose: boxPurpose,
                state: .unconfigured, detail: nil, credential: credential,
                error: "BOX_CLIENT_ID and BOX_CLIENT_SECRET must be set before TNG can be authorised",
                authorizePath: nil,
                remedy: "Take both from the Box Developer Console (§ Box OAuth2 in the README) and put them in .env.")
        }

        return ConnectionStatus(
            id: "box", name: "Box", purpose: boxPurpose,
            state: status.isWorking ? .working : .failing,
            detail: status.rootFolderName.map { "Uploading into \($0)" },
            credential: credential,
            error: status.error,
            // The one service TNG can re-authorise from here: Box hands out its tokens
            // through a browser redirect, which is exactly what this page can drive.
            authorizePath: "/admin/connections/box/authorize",
            remedy: nil)
    }

    /// How often the scheduled renewal runs, as the page says it.
    private static var renewalInterval: String {
        BoxTokenKeepAlive.describe(
            BoxTokenKeepAlive.interval(from: Environment.get("BOX_TOKEN_REFRESH_HOURS")))
    }

    private static let boxPurpose =
        "Where the band's official binders are published, in a folder per year."

    // MARK: - Slack

    private static func slackStatus(_ app: Application) async -> ConnectionStatus {
        let status = await app.slackService.status()
        let credential = status.hasWebhook
            ? "Bot token and incoming webhook set in .env"
            : "⚠ Bot token set, but SLACK_WEBHOOK_URL is missing: no build notifications"
        let remedy = """
            Slack's credentials are static configuration, not something TNG can renew. \
            Take a fresh bot token from the Slack app's OAuth & Permissions page and a \
            webhook URL from its Incoming Webhooks page, put them in .env as \
            SLACK_BOT_TOKEN and SLACK_WEBHOOK_URL, and restart.
            """

        if let error = status.error {
            let unset = error.contains("not set")
            return ConnectionStatus(
                id: "slack", name: "Slack", purpose: slackPurpose,
                state: unset ? .unconfigured : .failing,
                detail: nil, credential: credential, error: error,
                authorizePath: nil, remedy: remedy)
        }

        let workspace = status.workspace ?? "Slack"
        let bot = status.botUser.map { " as \($0)" } ?? ""
        return ConnectionStatus(
            id: "slack", name: "Slack", purpose: slackPurpose,
            state: status.hasWebhook ? .working : .failing,
            detail: "Connected to \(workspace)\(bot)",
            credential: credential,
            error: status.hasWebhook ? nil : "Build notifications have nowhere to go.",
            authorizePath: nil, remedy: remedy)
    }

    private static let slackPurpose =
        "Login links for the dashboard, and the build notification the band reads."

    // MARK: - Backups

    /// Not probed: a probe could only say the bucket is reachable now, and what matters is
    /// whether last night's copy landed — which the backup job records as it runs.
    private static func backupStatus(_ app: Application) async -> ConnectionStatus {
        let status = await DatabaseBackup.status(on: app.db)
        let remedy = """
            Set BACKUP_ENDPOINT, BACKUP_BUCKET, BACKUP_ACCESS_KEY and BACKUP_SECRET_KEY in \
            .env (README § Backups) and restart. Give TNG a key limited to that one bucket.
            """
        let credential = status.lastSuccess.map { last in
            "Last backup taken \(Self.relative(last))" + (status.lastObject.map { ": \($0)" } ?? "")
        } ?? "No backup has been stored yet"

        switch status.loaded {
        case .unconfigured:
            return ConnectionStatus(
                id: "backup", name: "Backups", purpose: backupPurpose,
                state: .unconfigured, detail: nil, credential: credential,
                error: "Backups are not configured: the database exists only on this server",
                authorizePath: nil, remedy: remedy)
        case .incomplete(let missing):
            return ConnectionStatus(
                id: "backup", name: "Backups", purpose: backupPurpose,
                state: .failing, detail: nil, credential: credential,
                error: "Missing \(missing.joined(separator: ", "))",
                authorizePath: nil, remedy: remedy)
        case .ready(let configuration):
            let interval = BoxTokenKeepAlive.describe(
                DatabaseBackup.interval(from: Environment.get("BACKUP_INTERVAL_HOURS")))
            let destination = "\(configuration.bucket)/\(configuration.prefix) at "
                + (configuration.endpoint.host ?? "") + ", every \(interval)"
            // Before the first run there is nothing to judge by, and a deployment that has
            // never stored a backup is not yet one that is backed up.
            let error: String? = switch status.healthy {
            case true?: nil
            case false?: "The last backup failed; the reason is in Slack and the server log"
            case nil: "No backup has run yet; the first runs a minute after the server starts"
            }
            return ConnectionStatus(
                id: "backup", name: "Backups", purpose: backupPurpose,
                state: status.healthy == true ? .working : .failing,
                detail: destination, credential: credential, error: error,
                authorizePath: nil, remedy: remedy)
        }
    }

    private static let backupPurpose =
        "A nightly copy of the database, kept off this server."

    // MARK: - Helpers

    /// "3 days ago", for a credential's age.
    ///
    /// Counted by hand rather than with `RelativeDateTimeFormatter`: this runs on Linux in
    /// production, where that API is a thin and historically unreliable part of
    /// corelibs-foundation, and the whole vocabulary needed here is hours and days.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return "just now" }

        let hours = Int(seconds / 3600)
        if hours < 1 { return "less than an hour ago" }
        if hours < 24 { return "\(hours) hour(s) ago" }
        return "\(hours / 24) day(s) ago"
    }
}
