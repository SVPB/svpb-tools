/// The lifecycle state of a build job.
///
/// Stored as a TEXT column in SQLite via Fluent's Codable serialisation.
/// Used by both the `Build` Fluent model and the `BuildSummary` DTO so that
/// the two share a single definition.
public enum BuildStatus: String, Codable, Sendable {
    case running
    case success
    /// The conversion finished, but at least one per-file or distribution step
    /// (a tune with no output, a Box upload, a catalogue upsert, the Slack
    /// notification) failed. The build log names each one.
    case partial
    case failure
}
