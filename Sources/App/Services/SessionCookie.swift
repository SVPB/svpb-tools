import Foundation
import Vapor

// MARK: - SessionCookie

/// The session cookie: its lifetime (#93) and its flags (#94).
///
/// The cookie is a full credential — whoever presents it is signed in as its user, admin
/// included, until it expires or is ended — so:
///
///   - it is always `HttpOnly`, so no script on a page can read it. TNG's own pages never
///     read it from script, so the flag costs nothing, and it keeps a future injection
///     bug in a template from becoming a stolen session;
///   - it is `Secure` wherever TNG is served over HTTPS (see ``isSecure(domain:)``), so a
///     browser never sends it on a plain-HTTP request, such as the first one to a typed
///     `http://` address before Caddy's redirect arrives;
///   - it stays `SameSite=Lax`: `Strict` would sign a user out of the page they reach by
///     following a link from Slack, which is how everyone arrives.
enum SessionCookie {

    /// The cookie's name, Vapor's default.
    static let name = "vapor-session"

    /// Whether the session cookie is `Secure`, decided from `DOMAIN`.
    ///
    /// `DOMAIN` is what the Slack login link is built from, always as `https://<DOMAIN>`,
    /// so wherever a login link really works the cookie it creates arrives over HTTPS.
    /// The cookie is not `Secure` when `DOMAIN` is unset or blank, or names `localhost`,
    /// `127.0.0.1` or `::1` (with or without a port): local development over
    /// `http://localhost` has to keep working.
    ///
    /// Not `app.environment`: production runs `./TNG serve` with no `--env`, so Vapor
    /// considers it `.development` (#95), and in any case `DOMAIN`, not the environment,
    /// is what decides whether the login link is HTTPS.
    static func isSecure(domain: String?) -> Bool {
        guard let domain = domain?.trimmingCharacters(in: .whitespaces), !domain.isEmpty else {
            return false
        }
        return !localHosts.contains(host(of: domain).lowercased())
    }

    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// The host part of a `DOMAIN` value: `[::1]:8080` → `::1`, `localhost:8080` →
    /// `localhost`. A bare IPv6 address, with more than one colon and no brackets, is all
    /// host.
    private static func host(of domain: String) -> Substring {
        if domain.hasPrefix("["), let close = domain.firstIndex(of: "]") {
            return domain[domain.index(after: domain.startIndex)..<close]
        }
        let colons = domain.filter { $0 == ":" }.count
        if colons == 1, let colon = domain.firstIndex(of: ":") {
            return domain[..<colon]
        }
        return domain[...]
    }

    /// The sessions configuration: Vapor's cookie name, a cookie that expires
    /// `policy.idleDays` from now, `HttpOnly`, `SameSite=Lax`, and `Secure` when
    /// `secure` is.
    ///
    /// The factory sees only the session ID, so the cookie can follow the idle limit but
    /// not the absolute one; the server enforces that (`SessionExpiry`).
    static func sessionsConfiguration(
        policy: SessionExpiry.Policy, secure: Bool
    ) -> SessionsConfiguration {
        let lifetime = policy.idleInterval
        return SessionsConfiguration(cookieName: name) { sessionID in
            HTTPCookies.Value(
                string: sessionID.string,
                expires: Date(timeIntervalSinceNow: lifetime),
                maxAge: nil,
                domain: nil,
                path: "/",
                isSecure: secure,
                isHTTPOnly: true,
                sameSite: .lax
            )
        }
    }
}
