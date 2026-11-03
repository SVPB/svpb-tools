import Fluent
import Foundation
import Vapor

// MARK: - UserSessions

/// A user's sign-in sessions: listing them, ending them, and naming the browser each one
/// is in (#90).
///
/// Sessions are Vapor's stock Fluent sessions, so a `_fluent_sessions` row holds only a
/// key and a `SessionData` blob. Everything known about a session is in that blob:
/// `userId` and `userRole` and ``userAgentKey`` from sign-in, and `SessionExpiry`'s
/// stamps. Finding a user's sessions means decoding every row and keeping those whose
/// `userId` matches. TNG has a band's worth of users, and `SessionSweeper` keeps the table
/// to live sessions, so the scan costs nothing — and matching inside the JSON in SQL would
/// tie this code to how `SessionData` happens to encode itself.
///
/// A session is named outside the server by its row's `id`, never its `key`: the key is
/// the cookie value, which is the credential itself.
enum UserSessions {

    /// Session data key for the `User-Agent` the session signed in with.
    static let userAgentKey = "userAgent"

    /// The longest `User-Agent` kept. Real ones are a few hundred characters; this only
    /// stops a made-up one from bloating every request's session write.
    static let maxUserAgentLength = 512

    /// `userAgent`, trimmed and cut to ``maxUserAgentLength``, or `nil` for none.
    static func storedUserAgent(_ userAgent: String?) -> String? {
        guard let trimmed = userAgent?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(maxUserAgentLength))
    }

    // MARK: Listing

    /// Every session row belonging to `userId`, expired or not.
    static func records(of userId: UUID, on db: any Database) async throws -> [SessionRecord] {
        let id = userId.uuidString
        return try await SessionRecord.query(on: db).all().filter { $0.data["userId"] == id }
    }

    /// The user's sessions that still sign them in at `now`, most recently used first.
    static func liveRecords(
        of userId: UUID, on db: any Database, now: Date, policy: SessionExpiry.Policy
    ) async throws -> [SessionRecord] {
        try await records(of: userId, on: db)
            .filter { !SessionExpiry.isExpired($0.data, now: now, policy: policy) }
            .sorted { lastSeen($0.data) > lastSeen($1.data) }
    }

    /// How many live sessions each user has. Users with none are absent.
    static func liveCounts(
        on db: any Database, now: Date, policy: SessionExpiry.Policy
    ) async throws -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for record in try await SessionRecord.query(on: db).all()
        where !SessionExpiry.isExpired(record.data, now: now, policy: policy) {
            guard let id = record.data["userId"].flatMap(UUID.init(uuidString:)) else { continue }
            counts[id, default: 0] += 1
        }
        return counts
    }

    private static func lastSeen(_ data: SessionData) -> Date {
        SessionExpiry.date(data[SessionExpiry.lastSeenAtKey]) ?? .distantPast
    }

    // MARK: Ending

    /// The row `sessionId` if it belongs to `userId`, otherwise `nil` — whether it doesn't
    /// exist or is someone else's, which a caller must not be able to tell apart.
    static func record(
        _ sessionId: UUID, of userId: UUID, on db: any Database
    ) async throws -> SessionRecord? {
        guard let record = try await SessionRecord.find(sessionId, on: db),
              record.data["userId"] == userId.uuidString else { return nil }
        return record
    }

    /// Deletes every session row of `userId` except the one whose key is `keeping`, and
    /// returns how many went.
    @discardableResult
    static func endAll(
        of userId: UUID, keeping: SessionID? = nil, on db: any Database
    ) async throws -> Int {
        var count = 0
        for record in try await records(of: userId, on: db) where record.key != keeping {
            try await record.delete(on: db)
            count += 1
        }
        return count
    }

    // MARK: Naming the browser

    /// A short name for the browser a `User-Agent` describes, such as "Safari on iPhone"
    /// or "Firefox on Mac". Only the common browsers and systems are recognised; anything
    /// else is "Unknown browser", or "A browser on …" when the system is known.
    static func deviceLabel(userAgent: String?) -> String {
        guard let ua = userAgent, !ua.isEmpty else { return "Unknown browser" }
        let browser = browserName(ua)
        let system = systemName(ua)
        switch (browser, system) {
        case let (browser?, system?): return "\(browser) on \(system)"
        case let (browser?, nil): return browser
        case let (nil, system?): return "A browser on \(system)"
        case (nil, nil): return "Unknown browser"
        }
    }

    /// Tested in this order because each browser's string names the ones it imitates:
    /// Edge and Opera say Chrome, Chrome says Safari.
    private static func browserName(_ ua: String) -> String? {
        if ua.contains("Edg/") || ua.contains("EdgA/") || ua.contains("EdgiOS/") { return "Edge" }
        if ua.contains("OPR/") || ua.contains("Opera") { return "Opera" }
        if ua.contains("Firefox/") || ua.contains("FxiOS/") { return "Firefox" }
        if ua.contains("Chrome/") || ua.contains("CriOS/") || ua.contains("Chromium/") { return "Chrome" }
        if ua.contains("Safari/") || ua.contains("AppleWebKit/") { return "Safari" }
        return nil
    }

    /// iPhone and iPad before Mac, and Android and ChromeOS before Linux, for the same
    /// reason.
    private static func systemName(_ ua: String) -> String? {
        if ua.contains("iPhone") || ua.contains("iPod") { return "iPhone" }
        if ua.contains("iPad") { return "iPad" }
        if ua.contains("Android") { return "Android" }
        if ua.contains("CrOS") { return "ChromeOS" }
        if ua.contains("Macintosh") || ua.contains("Mac OS X") { return "Mac" }
        if ua.contains("Windows") { return "Windows" }
        if ua.contains("Linux") { return "Linux" }
        return nil
    }
}
