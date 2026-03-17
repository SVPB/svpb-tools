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

    // MARK: BoxService

    private struct BoxServiceKey: StorageKey { typealias Value = BoxService }

    var boxService: BoxService {
        get { storage[BoxServiceKey.self]! }
        set { storage[BoxServiceKey.self] = newValue }
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
