import Foundation
@testable import App

/// An `ArtifactDestination` that publishes nowhere, for driving the build's publishing
/// path without Box (#85).
///
/// It records the name of every file it is asked to publish, and fails the ones named
/// in `failing` — or all of them while `failsEverything` is set — so a test can make an
/// upload fail on one build and succeed on the next.
actor StubDestination: ArtifactDestination {

    struct Refused: Error, CustomStringConvertible {
        let filename: String
        var description: String { "stub refused \(filename)" }
    }

    nonisolated let displayName = "Stub"

    static let browseURL = URL(string: "https://stub.example/2026")!

    private(set) var published: [String] = []
    private var failing: Set<String> = []
    private var failsEverything: Bool

    init(failsEverything: Bool = false) {
        self.failsEverything = failsEverything
    }

    /// Makes exactly `filenames` fail from now on; an empty set lets everything through.
    func fail(_ filenames: Set<String>) {
        failsEverything = false
        failing = filenames
    }

    /// Forgets what has been published, so a test can look at one build at a time.
    func resetPublished() {
        published = []
    }

    func publish(_ file: URL, forBranch branch: String) async throws -> PublishedLocation {
        let name = file.lastPathComponent
        guard !failsEverything, !failing.contains(name) else { throw Refused(filename: name) }
        published.append(name)
        return PublishedLocation(browseURL: Self.browseURL)
    }

    func connectionStatus() async -> ConnectionStatus {
        ConnectionStatus(
            id: "stub", name: displayName, purpose: "Where test binders go.",
            state: .working, detail: nil, credential: nil, error: nil,
            authorizePath: nil, remedy: nil)
    }
}
