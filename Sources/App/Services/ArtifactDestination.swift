import Foundation

// MARK: - ArtifactDestination

/// Wherever a build's official binders are published, as far as the build is concerned (#85).
///
/// A build needs two things from it: put this file in this branch's place, and say where
/// people can go to look at it. Everything else — credentials, how a branch maps onto a
/// folder, what the service calls a folder — belongs to the destination. `BoxService` is
/// the first.
///
/// **A destination must replace a file in place.** Publishing a binder again under the
/// same name has to replace the earlier file without breaking a link someone has already
/// bookmarked: the band's bookmarks are the reason the binders are published at all. Box
/// does this by adding a new version of the same file. A storage service that cannot do
/// it cannot be a destination.
///
/// Which destination is in use is the band's policy, not a property of a binder, so
/// `BinderUpload` records whether a binder was delivered, not where to. A binder still
/// waiting when the destination changes is current output that was never delivered, and
/// the next build sends it to the new one.
protocol ArtifactDestination: Sendable {

    /// Stable identifier: `box`. The id of its connection card, and the prefix of the
    /// settings kept for it, such as its keep-alive's health (#86).
    var id: String { get }

    /// "Box", "Google Drive": what the build log, Slack and the connections page call it.
    var displayName: String { get }

    /// Puts `file` in the place for `branch`, replacing an earlier file of the same name.
    ///
    /// - Parameters:
    ///   - file: Local path of the binder. Its last path component is the name it is
    ///     published under.
    ///   - branch: The git branch the binder was built from, e.g. `"2026"`.
    func publish(_ file: URL, forBranch branch: String) async throws -> PublishedLocation

    /// This destination's card on the connections page.
    ///
    /// Each destination writes its own, because only it knows what its configuration is
    /// and what fixes it.
    func connectionStatus() async -> ConnectionStatus
}

// MARK: - AuthorizableDestination

/// A destination whose credential is an OAuth grant, which TNG obtains from the
/// connections page and keeps alive on a timer (#86).
///
/// Opting in gets a destination three things: an Authorise button on its connection
/// card, driving the consent flow through ``authorizationURL(redirectURI:state:)`` and
/// ``adoptAuthorizationCode(_:redirectURI:)``; a callback route at ``callbackPath``; and
/// `DestinationKeepAlive`, which calls ``renew()`` on a schedule and tells Slack when the
/// outcome changes. A destination with fixed keys, such as an S3 bucket, conforms to
/// `ArtifactDestination` alone and gets none of it.
///
/// How the token is stored is not part of this. Box retires its refresh token on every
/// refresh and Google normally keeps the same one, so each destination saves its own,
/// under its own `Setting` key, whenever it changes.
protocol AuthorizableDestination: ArtifactDestination {

    /// The server path the provider sends the browser back to, e.g. `/box-callback`.
    ///
    /// Each destination declares its own, because the address is registered in the
    /// provider's console and changing it means changing that registration too.
    var callbackPath: String { get }

    /// How long the credential survives without use — 60 days for a Box refresh token —
    /// or `nil` when it does not expire from disuse. The connections page counts down
    /// from the last renewal with it.
    var credentialLifetime: TimeInterval? { get }

    /// Where the operator is sent to grant TNG access.
    ///
    /// - Parameters:
    ///   - redirectURI: The full address of ``callbackPath`` on this server. Must be the
    ///     one later given to ``adoptAuthorizationCode(_:redirectURI:)``.
    ///   - state: Opaque value echoed back to the callback, checked against the session.
    func authorizationURL(redirectURI: String, state: String) async -> String

    /// Exchanges the code from the provider's redirect for a credential, stores it, and
    /// takes it into use. Throws unless a usable credential is left behind.
    func adoptAuthorizationCode(_ code: String, redirectURI: String) async throws

    /// Renews the credential whether or not it is due, so it cannot die of disuse.
    func renew() async throws
}

// MARK: - PublishedLocation

/// Where a published binder can be found.
struct PublishedLocation: Sendable, Equatable {
    /// A page where people can see the branch's binders, if the destination has one.
    let browseURL: URL?
}
