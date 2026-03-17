/// The lifecycle state of a build job.
///
/// Stored as a TEXT column in SQLite via Fluent's Codable serialisation.
/// Used by both the `Build` Fluent model and the `BuildSummary` DTO so that
/// the two share a single definition.
public enum BuildStatus: String, Codable, Sendable {
    case running
    case success
    case failure
}
