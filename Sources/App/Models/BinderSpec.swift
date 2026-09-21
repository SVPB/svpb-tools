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
/// ## Table of contents
///
/// A section may declare itself the binder's table of contents (#47) rather
/// than being a title page or a run of tunes. It expands at assembly into one
/// line per listed thing, each carrying the page it starts on.
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

    /// The title as one run of text, for a line that has no room to stack it —
    /// a contents entry, or the heading over a table of contents (#47).
    public var oneLine: String { pageLines.joined(separator: " ") }

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

// MARK: - TableOfContentsSpec

/// A declared table of contents: the pages listing what the binder holds and
/// where each of them starts (#47).
///
/// Written as a flag where nothing more is wanted, or as a mapping that narrows
/// what is listed:
/// ```yaml
/// - toc: true
/// - toc:
///     include: [tunes]
/// ```
/// A contents listing always covers the **whole** binder, wherever in it the
/// contents pages sit — a binder may declare more than one, and each says the
/// same thing.
public struct TableOfContentsSpec: Codable, Sendable, Equatable {

    /// A kind of thing a contents listing names.
    public enum Listing: String, Codable, Sendable, CaseIterable {
        /// The title page over a run of tunes, listed at the page it occupies.
        case sections
        /// Each tune, listed at the page it opens on.
        case tunes
    }

    /// What this listing names, in the order the kinds nest. Both by default.
    public let include: [Listing]

    /// - Parameter include: The kinds to list. Order and repeats are ignored:
    ///   the value is normalised to `Listing.allCases` order.
    public init(include: [Listing] = Listing.allCases) {
        self.include = Listing.allCases.filter(include.contains)
    }

    /// Whether section titles get a line of their own.
    public var listsSections: Bool { include.contains(.sections) }

    /// Whether each tune gets a line of its own.
    public var listsTunes: Bool { include.contains(.tunes) }

    /// True when the listing would name nothing at all, which is a contents
    /// page carrying only its heading.
    public var isEmpty: Bool { include.isEmpty }

    enum CodingKeys: String, CodingKey {
        case include
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(include: try container.decodeIfPresent([Listing].self, forKey: .include)
            ?? Listing.allCases)
    }

    /// Encodes back to the shape it was written in: the bare `true` when it
    /// lists everything, and the mapping only when it has been narrowed. A spec
    /// stored or shared before narrowing existed is unchanged by a round trip.
    public func encode(to encoder: any Encoder) throws {
        guard include != Listing.allCases else {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(include, forKey: .include)
    }

    /// The contents declaration under `key`, or `nil` where there is none.
    ///
    /// `toc: true` and `toc: { include: … }` both declare one; `toc: false`,
    /// `toc: null`, and an absent key all decline one, so a section can say
    /// "not a table of contents" as plainly as it says the opposite.
    static func decode<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> TableOfContentsSpec? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        if let declared = try? container.decode(Bool.self, forKey: key) {
            return declared ? TableOfContentsSpec() : nil
        }
        return try container.decode(TableOfContentsSpec.self, forKey: key)
    }
}

// MARK: - BinderSection

/// A run of consecutive tunes in a binder, optionally introduced by a title page.
///
/// Either half may be missing. A section with entries and no title is a run of
/// tunes that simply follows the previous section's; a section with a title and
/// no entries is a title page on its own, which is what makes binder front
/// matter and consecutive title pages expressible (#46).
///
/// A section may instead declare itself the binder's table of contents (#47).
/// That is a third kind of thing rather than a title page with a list under it:
/// its `title`, if it has one, is the heading printed over the listing rather
/// than a title page of its own, and it holds no tunes.
public struct BinderSection: Codable, Content, Sendable {

    /// The title page ahead of this section. `nil`, empty, or all-whitespace
    /// means the section has no title page.
    ///
    /// On a contents section this is the heading over the listing instead, and
    /// a section without one is headed ``TableOfContentsRenderer/defaultHeading``.
    public let title: BinderTitle?

    /// Ordered list of tune+part selections in this section. Empty when the
    /// section is a title page and nothing more.
    public let entries: [BinderEntry]

    /// The table of contents this section is, or `nil` when it is not one (#47).
    public let toc: TableOfContentsSpec?

    public init(title: BinderTitle?, entries: [BinderEntry], toc: TableOfContentsSpec? = nil) {
        self.title = title
        self.entries = entries
        self.toc = toc
    }

    /// The title page to engrave ahead of this section, or `nil` when there is
    /// none — which a contents section never has, its title being a heading.
    public var titlePage: BinderTitle? {
        guard toc == nil, let title, !title.isEmpty else { return nil }
        return BinderTitle(title.pageLines)
    }

    /// The heading printed over this section's contents listing.
    public var contentsHeading: String {
        guard let title, !title.isEmpty else { return TableOfContentsRenderer.defaultHeading }
        return title.oneLine
    }

    enum CodingKeys: String, CodingKey {
        case title, entries, toc
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(BinderTitle.self, forKey: .title)
        entries = try container.decodeIfPresent([BinderEntry].self, forKey: .entries) ?? []
        toc = try TableOfContentsSpec.decode(from: container, forKey: .toc)
    }

    /// Writes `toc` only when there is one, so every spec written before a
    /// binder could carry a contents listing encodes byte-identically.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(entries, forKey: .entries)
        try container.encodeIfPresent(toc, forKey: .toc)
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
