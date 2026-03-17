import Vapor

// MARK: - BinderSpec

/// The machine-readable definition of a personalised binder.
///
/// A binder is always scoped to a single branch (year).  Each entry selects a
/// tune by slug and one or more named parts to include.
///
/// Example (encoded as the `definition` JSON column in `BinderRequest`):
/// ```json
/// {
///   "name": "My Binder - March 2026",
///   "branch": "2026",
///   "entries": [
///     { "tune_slug": "archie_beag",        "parts": ["Harmony 1"] },
///     { "tune_slug": "scotland_the_brave", "parts": ["Melody", "Harmony 1"] }
///   ]
/// }
/// ```
public struct BinderSpec: Codable, Content, Sendable {

    /// Display name for this binder, chosen by the musician.
    public let name: String

    /// Git branch (year) that all entries in this binder draw from.
    public let branch: String

    /// Ordered list of tune+part selections.
    public let entries: [BinderEntry]

    public init(name: String, branch: String, entries: [BinderEntry]) {
        self.name = name
        self.branch = branch
        self.entries = entries
    }
}

// MARK: - BinderEntry

/// One row in a binder: a tune identified by slug and one or more part names.
public struct BinderEntry: Codable, Content, Sendable {

    /// Stable slug for the tune, matching `Tune.slug`.
    public let tuneSlug: String

    /// One or more part names to include, e.g. `["Melody", "Harmony 1"]`.
    public let parts: [String]

    public init(tuneSlug: String, parts: [String]) {
        self.tuneSlug = tuneSlug
        self.parts = parts
    }

    enum CodingKeys: String, CodingKey {
        case tuneSlug = "tune_slug"
        case parts
    }
}
