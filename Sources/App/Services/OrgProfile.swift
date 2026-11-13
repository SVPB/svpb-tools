import Fluent
import Leaf
import Synchronization
import Vapor

// MARK: - OrgNames

/// What the organisation running this deployment is called (#89).
///
/// TNG is the software's name, not the band's, so it stays in every form; the band's names
/// are added to it when they are set. A deployment that sets neither looks like neutral TNG.
struct OrgNames: Equatable, Sendable {
    /// The long form, e.g. "Silicon Valley Pipe Band". Shown on the sign-in page.
    var name: String?
    /// The short form, e.g. "SVPB". Prefixed to "TNG" in titles, the header and footers.
    var shortName: String?

    init(name: String? = nil, shortName: String? = nil) {
        self.name = name
        self.shortName = shortName
    }

    /// What the site calls itself: "SVPB TNG", or "TNG" with no short name.
    var siteName: String {
        shortName.map { "\($0) TNG" } ?? "TNG"
    }

    /// The sign-in page's subtitle: "Silicon Valley Pipe Band · Tools Next Generation", or
    /// "Tools Next Generation" with no long name.
    var subtitle: String {
        [name, "Tools Next Generation"].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - OrgProfile

/// The organisation's names, held for the life of the process so templates can read them
/// without every controller putting them in its context (#89).
///
/// Loaded once at startup and replaced when the Organisation admin page saves. Reads come
/// from Leaf's renderer, on any event loop, so the value is behind a lock.
final class OrgProfile: Sendable {

    /// The long name's environment variable; an admin's `org.name` setting overrides it.
    static let nameVariable = "ORG_NAME"
    /// The short name's environment variable; an admin's `org.short_name` setting
    /// overrides it.
    static let shortNameVariable = "ORG_SHORT_NAME"

    private let state: Mutex<OrgNames>

    init(_ names: OrgNames = OrgNames()) {
        state = Mutex(names)
    }

    /// The names in force now.
    var names: OrgNames {
        state.withLock { $0 }
    }

    /// Replaces the names, for every page rendered from now on.
    func replace(with names: OrgNames) {
        state.withLock { $0 = names }
    }

    /// Reads the names again from the settings and the environment, and puts them in force.
    func reload(on db: any Database, environment: (String) -> String? = Environment.get) async throws {
        replace(with: try await Self.resolve(on: db, environment: environment).names)
    }

    // MARK: Resolving

    /// The names in force and where each came from, for the admin page.
    struct Resolved: Sendable {
        let names: OrgNames
        let nameSource: Setting.Source
        let shortNameSource: Setting.Source
    }

    /// Each name is an admin's setting, else its environment variable, else unset.
    static func resolve(
        on db: any Database,
        environment: (String) -> String? = Environment.get
    ) async throws -> Resolved {
        let name = try await Setting.layered(
            Setting.orgName, environmentKey: nameVariable, on: db, environment: environment)
        let shortName = try await Setting.layered(
            Setting.orgShortName, environmentKey: shortNameVariable, on: db, environment: environment)
        return Resolved(
            names: OrgNames(name: name.value, shortName: shortName.value),
            nameSource: name.source,
            shortNameSource: shortName.source
        )
    }
}

// MARK: - Application storage

extension Application {

    private struct OrgProfileKey: StorageKey { typealias Value = OrgProfile }

    /// The organisation's names (#89). Set in `configure`; an application that has not
    /// set one reads as neutral TNG.
    var orgProfile: OrgProfile {
        get { storage[OrgProfileKey.self] ?? OrgProfile() }
        set { storage[OrgProfileKey.self] = newValue }
    }
}

// MARK: - The Leaf tag

/// `#org("…")`: the organisation's names, in templates (#89).
///
/// - `#org("site")`: "SVPB TNG", or "TNG" with no short name — titles, header, footers.
/// - `#org("subtitle")`: "Silicon Valley Pipe Band · Tools Next Generation", or just
///   "Tools Next Generation" with no long name.
/// - `#org("name")`, `#org("short")`: the long and short names, or empty.
///
/// Output is HTML-escaped like any other tag's, so a name containing `<` is shown, not
/// interpreted.
struct OrgTag: LeafTag {

    static let name = "org"
    private static let fields = #""site", "subtitle", "name" or "short""#

    func render(_ ctx: LeafContext) throws -> LeafData {
        try ctx.requireParameterCount(1)
        guard let key = ctx.parameters[0].string else {
            throw Abort(.internalServerError, reason: "#org takes a field name: \(Self.fields)")
        }
        let names = ctx.application?.orgProfile.names ?? OrgNames()
        switch key {
        case "site":     return .string(names.siteName)
        case "subtitle": return .string(names.subtitle)
        case "name":     return .string(names.name ?? "")
        case "short":    return .string(names.shortName ?? "")
        default:
            throw Abort(.internalServerError, reason: "#org has no field \"\(key)\"; use \(Self.fields)")
        }
    }
}
