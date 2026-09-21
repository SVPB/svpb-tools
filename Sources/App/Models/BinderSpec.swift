import Vapor

// MARK: - BinderSpec

/// The machine-readable definition of a personalised binder.
///
/// A binder is always scoped to a single branch (year). Its contents are grouped
/// into ordered sections; a titled section gets a title page ahead of it in the
/// generated PDF, and an untitled one does not.
///
/// Example (encoded as the `definition` JSON column in `BinderRequest`):
/// ```json
/// {
///   "name": "My Binder - March 2026",
///   "branch": "2026",
///   "sections": [
///     { "title": ["SVPB Music", "2026"], "entries": [] },
///     { "title": null,
///       "entries": [ { "tune_slug": "amazing_grace", "parts": ["Melody"] } ] },
///     { "title": "Parade Set",
///       "entries": [ { "tune_slug": "archie_beag",        "parts": ["Harmony 1"] },
///                    { "tune_slug": "scotland_the_brave", "parts": ["Melody"] } ] }
///   ]
/// }
/// ```
///
/// Sections nest rather than sitting inline as title markers in one flat list
/// so that this shape matches the `sections` of `binders.yaml`, which the shared
/// tune-selection component also has to produce for the binder constructor.
///
/// ## Title pages
///
/// A section that holds no entries is not an error and is not dropped: it is a
/// title page and nothing else (#46). That is how a binder gets front matter
/// that belongs to the binder rather than to the tunes after it, and how two
/// title pages come to sit on consecutive pages — each is its own section.
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

    /// Ordered sections, each an ordered list of tune+part selections, a title
    /// page, or both.
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

// MARK: - BinderTitle

/// The text engraved on one title page: one line, or several stacked as a block.
///
/// Written as either a string or a list of strings, so every title written
/// before multi-line titles existed (#46) still decodes:
/// ```json
/// "title": "Parade Set"
/// "title": ["SVPB Music", "2027"]
/// ```
/// and a one-line title encodes back to the bare string it came in as, which
/// keeps stored `BinderRequest` definitions and shared URLs byte-identical
/// across this change.
public struct BinderTitle: Codable, Sendable, Equatable,
                           ExpressibleByStringLiteral, ExpressibleByArrayLiteral {

    /// The lines as written, before any tidying. See ``pageLines``.
    public let lines: [String]

    public init(_ lines: [String]) {
        self.lines = lines
    }

    public init(stringLiteral value: String) {
        self.lines = [value]
    }

    public init(arrayLiteral elements: String...) {
        self.lines = elements
    }

    /// The lines actually engraved: each with its internal whitespace collapsed
    /// and its ends trimmed, and blank lines dropped.
    ///
    /// Empty when the title has nothing to draw, which is how a title that is
    /// only whitespace comes to mean "no title page" rather than "a blank page".
    public var pageLines: [String] {
        lines
            .map { $0.replacing(/[\s\p{Cc}]+/, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// True when this title would engrave nothing.
    public var isEmpty: Bool { pageLines.isEmpty }

    /// The title on one line, for logs and error messages.
    public var display: String { pageLines.joined(separator: " / ") }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            lines = [single]
        } else {
            lines = try container.decode([String].self)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if lines.count == 1 {
            try container.encode(lines[0])
        } else {
            try container.encode(lines)
        }
    }
}

// MARK: - BinderSection

/// A run of consecutive tunes in a binder, optionally introduced by a title page.
///
/// Either half may be missing. A section with entries and no title is a run of
/// tunes that simply follows the previous section's; a section with a title and
/// no entries is a title page on its own, which is what makes binder front
/// matter and consecutive title pages expressible (#46).
public struct BinderSection: Codable, Content, Sendable {

    /// The title page ahead of this section. `nil`, empty, or all-whitespace
    /// means the section has no title page.
    public let title: BinderTitle?

    /// Ordered list of tune+part selections in this section. Empty when the
    /// section is a title page and nothing more.
    public let entries: [BinderEntry]

    public init(title: BinderTitle?, entries: [BinderEntry]) {
        self.title = title
        self.entries = entries
    }

    /// The title page to engrave ahead of this section, or `nil` when there is none.
    public var titlePage: BinderTitle? {
        guard let title, !title.isEmpty else { return nil }
        return BinderTitle(title.pageLines)
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
