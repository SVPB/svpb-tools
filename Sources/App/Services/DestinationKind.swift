import Foundation

// MARK: - DestinationKind

/// Which `ArtifactDestination` this server publishes to, named by `ARTIFACT_DESTINATION`
/// in `.env` (#87).
///
/// One destination per server: a second band runs its own deployment, so this is a
/// setting of the deployment rather than data in the database. It lives in `.env`, not on
/// an admin page, because choosing a destination means choosing which credentials apply,
/// and those live in `.env` too.
///
/// Switching moves nothing. Binders already published stay where they are; the new
/// destination gets each branch's binders from its next build, along with any still
/// waiting for delivery at the switch (#85).
enum DestinationKind: String, CaseIterable, Sendable {
    case box
    case googleDrive = "google_drive"

    /// The environment variable that names the destination.
    static let environmentKey = "ARTIFACT_DESTINATION"

    /// Unset means Box, so a deployment from before #87 needs no change.
    static let defaultKind: DestinationKind = .box

    /// Reads `ARTIFACT_DESTINATION`. Unset or blank is ``defaultKind``; anything else that
    /// is not an accepted value stops startup, with a message listing the accepted ones.
    static func load(from get: (String) -> String?) throws -> DestinationKind {
        let raw = (get(environmentKey) ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return defaultKind }
        guard let kind = DestinationKind(rawValue: raw) else {
            throw ConfigurationError.unrecognisedDestination(raw)
        }
        return kind
    }

    /// The variables this destination cannot start without.
    ///
    /// `BOX_REFRESH_TOKEN` is deliberately *not* among Box's. It is the one credential the
    /// server can obtain for itself — from `/admin/connections`, which a deployment has to
    /// be able to boot far enough to reach. Refusing to start without one would mean a
    /// fresh deployment could never be authorised at all.
    var requiredEnvironmentVariables: [String] {
        switch self {
        case .box: ["BOX_CLIENT_ID", "BOX_CLIENT_SECRET", "BOX_FOLDER_ID"]
        // `GOOGLE_REFRESH_TOKEN` is optional for the same reason as Box's.
        case .googleDrive: ["GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GOOGLE_DRIVE_FOLDER_NAME"]
        }
    }

    /// The accepted values of `ARTIFACT_DESTINATION`, for the startup error.
    static var acceptedValues: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}
