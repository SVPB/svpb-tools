import AsyncHTTPClient
import Vapor

// MARK: - Application service storage
//
// Each service is stored in Application.storage using a private StorageKey.
// Services are initialised in configure.swift and accessed from request
// handlers via `req.application.<serviceName>`.

extension Application {

    // MARK: BuildService

    private struct BuildServiceKey: StorageKey { typealias Value = BuildService }

    var buildService: BuildService {
        get { storage[BuildServiceKey.self]! }
        set { storage[BuildServiceKey.self] = newValue }
    }

    // MARK: SlackService

    private struct SlackServiceKey: StorageKey { typealias Value = SlackService }

    var slackService: SlackService {
        get { storage[SlackServiceKey.self]! }
        set { storage[SlackServiceKey.self] = newValue }
    }

    // MARK: GitService

    private struct GitServiceKey: StorageKey { typealias Value = GitService }

    var gitService: GitService {
        get { storage[GitServiceKey.self]! }
        set { storage[GitServiceKey.self] = newValue }
    }

    // MARK: ArtifactDestination

    private struct ArtifactDestinationKey: StorageKey { typealias Value = any ArtifactDestination }

    /// Where the build publishes official binders (#85): the one `ARTIFACT_DESTINATION`
    /// names (#87).
    var artifactDestination: any ArtifactDestination {
        get { storage[ArtifactDestinationKey.self]! }
        set { storage[ArtifactDestinationKey.self] = newValue }
    }

    /// The destination, when its credential is an OAuth grant TNG obtains and renews
    /// itself (#86); `nil` for one with fixed keys.
    var authorizableDestination: (any AuthorizableDestination)? {
        artifactDestination as? any AuthorizableDestination
    }

    // MARK: BinderService

    private struct BinderServiceKey: StorageKey { typealias Value = BinderService }

    var binderService: BinderService {
        get { storage[BinderServiceKey.self]! }
        set { storage[BinderServiceKey.self] = newValue }
    }

    // MARK: Shared HTTPClient

    private struct SharedHTTPClientKey: StorageKey { typealias Value = HTTPClient }

    /// A single `AsyncHTTPClient.HTTPClient` shared by all services.
    /// Shutdown is performed in `configure.swift` via `app.lifecycle`.
    var sharedHTTPClient: HTTPClient {
        get { storage[SharedHTTPClientKey.self]! }
        set { storage[SharedHTTPClientKey.self] = newValue }
    }
}

// MARK: - HTTPClient lifecycle

/// Shuts down the shared HTTPClient cleanly when the application stops.
struct HTTPClientLifecycleHandler: LifecycleHandler {
    func shutdown(_ application: Application) {
        try? application.sharedHTTPClient.syncShutdown()
    }
}
