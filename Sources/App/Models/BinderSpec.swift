import Vapor

// MARK: - BinderSpec

/// The machine-readable definition of a personalised binder.
///
/// A binder is always scoped to a single branch (year). Its tunes are grouped
/// into ordered sections; a section with a title gets a divider page ahead of
/// it in the generated PDF, and a section without one does not.
///
/// Example (encoded as the `definition` JSON column in `BinderRequest`):
/// ```json
/// {
///   "name": "My Binder - March 2026",
///   "branch": "2026",
///   "sections": [
///     { "title": null,
///       "entries": [ { "tune_slug": "amazing_grace", "parts": ["Melody"] } ] },
///     { "title": "Parade Set",
///       "entries": [ { "tune_slug": "archie_beag",        "parts": ["Harmony 1"] },
///                    { "tune_slug": "scotland_the_brave", "parts": ["Melody"] } ] }
///   ]
/// }
/// ```
///
/// Sections nest rather than sitting inline as divider markers in one flat list
/// so that this shape matches the `sections` of `binders.yaml`, which the shared
/// tune-selection component also has to produce for the binder constructor.
///
/// ## The flat shape
///
/// Binders created before sections existed were stored, and shared by URL, as a
/// flat `entries` array with no `sections` key. Those still decode, as a single
/// untitled section. Encoding always writes `sections`.
public struct BinderSpec: Codable, Content, Sendable {

    /// Display name for this binder, chosen by the musician.
    public let name: String

    /// Git branch (year) that all entries in this binder draw from.
    public let branch: String

    /// Ordered sections, each an ordered list of tune+part selections.
    public let sections: [BinderSection]

    public init(name: String, branch: String, sections: [BinderSection]) {
        self.name = name
        self.branch = branch
        self.sections = sections
    }

    /// Every entry in binder order, across all sections.
    public var entries: [BinderEntry] {
        sections.flatMap(\.entries)
    }

    enum CodingKeys: String, CodingKey {
        case name, branch, sections, entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        branch = try container.decode(String.self, forKey: .branch)
        if let sections = try container.decodeIfPresent([BinderSection].self, forKey: .sections) {
            self.sections = sections
        } else {
            let entries = try container.decode([BinderEntry].self, forKey: .entries)
            sections = [BinderSection(title: nil, entries: entries)]
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(branch, forKey: .branch)
        try container.encode(sections, forKey: .sections)
    }
}

// MARK: - BinderSection

/// A run of consecutive tunes in a binder, optionally introduced by a divider page.
public struct BinderSection: Codable, Content, Sendable {

    /// The divider page title. `nil`, empty, or all-whitespace means the section
    /// has no divider and its tunes simply follow the previous section's.
    public let title: String?

    /// Ordered list of tune+part selections in this section.
    public let entries: [BinderEntry]

    public init(title: String?, entries: [BinderEntry]) {
        self.title = title
        self.entries = entries
    }

    /// The title to print on the divider page, or `nil` when there is no divider.
    public var dividerTitle: String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
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
