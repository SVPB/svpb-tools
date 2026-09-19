import Foundation
import Vapor

// MARK: - ConnectionStatus

/// One external service TNG depends on, as the connections page reports it.
///
/// Every remote service that needs a credential belongs here, whether or not TNG can do
/// anything about it from a browser: an operator diagnosing "the binders aren't turning
/// up" should have one page that says which link in the chain is broken, rather than
/// three places to look and a build log to read.
///
/// Adding a service means producing one of these from whatever that service can be asked
/// about — see `ConnectionsReport`.
struct ConnectionStatus: Content, Equatable {

    /// How the connection is doing, in the only three states worth distinguishing.
    enum State: String, Content {
        /// TNG reached the service and was accepted.
        case working
        /// TNG has credentials and they did not work.
        case failing
        /// TNG has not been given what it needs to try.
        case unconfigured
    }

    /// Stable identifier, used in routes and as the DOM id: `box`, `slack`, `github`.
    let id: String

    /// Display name.
    let name: String

    /// What TNG uses this service for, in one line — so the page explains what breaks
    /// when a row is red, not just that something is.
    let purpose: String

    let state: State

    /// What TNG found on the other end: the folder name, the Slack workspace, the
    /// repository. Present when `state` is `working`.
    let detail: String?

    /// The credential's own story: what is stored, when it was last renewed, when it
    /// expires. Independent of whether the service answered just now.
    let credential: String?

    /// Why the service could not be reached, verbatim.
    let error: String?

    /// Where a "Re-authorise" button should point, for a service TNG can re-authorise
    /// from the browser. `nil` for a service whose credential is static configuration.
    let authorizePath: String?

    /// What to do by hand when there is no button — which environment variable to change,
    /// and where its value comes from.
    let remedy: String?

    // MARK: - Convenience

    // No `isWorking` convenience here on purpose: the templates that draw this are the
    // main reader, and Leaf sees only the encoded stored properties — a computed helper
    // would silently be `false` in every `#if` that used it. Templates compare `state`.

    /// Box refresh tokens expire after this long without use. Nothing else TNG talks to
    /// has an expiring credential today.
    static let boxTokenLifetime: TimeInterval = 60 * 24 * 60 * 60
}
