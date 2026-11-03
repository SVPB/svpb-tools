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

// MARK: - PublishedLocation

/// Where a published binder can be found.
struct PublishedLocation: Sendable, Equatable {
    /// A page where people can see the branch's binders, if the destination has one.
    let browseURL: URL?
}
