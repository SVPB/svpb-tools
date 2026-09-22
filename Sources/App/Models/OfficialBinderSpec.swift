import Foundation

// MARK: - BindersFile

/// The contents of `binders.yaml`: the band's official binders for one branch.
///
/// The file lives at the root of each branch of the music repository, so the
/// branch (year) is implicit and there is no `branch` field. Example:
/// ```yaml
/// binders:
///   - name: "2026 Band Binder"
///     output: 2026_binder.pdf
///     pack: true                       # short tunes share pages (#48)
///     sections:
///       - title: ["SVPB Music", "2026"]   # front matter: a title page, no tunes
///       - toc: true                      # the table of contents (#47)
///       - title: "Grade 4 Tunes"
///         entries:
///           - tune: g4_medley_2026
///           - tune: Moonstar
///             parts: ["Melody", "Seconds"]
///             break: before            # this one starts a page of its own
/// ```
///
/// This is a different type from the personal `BinderSpec` on purpose: entries
/// here say `tune:`, not `tune_slug:`, `parts` is optional, and every section
/// that is not a table of contents has a title.
struct BindersFile: Codable, Sendable {

    /// The binders the file declares, in file order.
    let binders: [OfficialBinder]
}

// MARK: - OfficialBinder

/// One official binder declared in `binders.yaml`.
struct OfficialBinder: Codable, Sendable {

    /// Display name, shown in the UI and the build log.
    let name: String

    /// Filename of the assembled PDF, e.g. `2026_binder.pdf`. This is the name
    /// the binder is written and uploaded under, so it must be a bare filename.
    let output: String

    /// Ordered sections: each a title page, a titled run of tunes, or the binder's
    /// table of contents (#47).
    let sections: [OfficialBinderSection]

    /// Whether consecutive tunes may share a page (#48).
    ///
    /// Absent means no, which is how every `binders.yaml` written so far reads and
    /// what every official binder assembled so far did: one tune, one page. A binder
    /// that says `pack: true` gets the paper back, and an entry that must open a page
    /// anyway says so with `break: before`.
    let pack: Bool

    // Spelled out because both halves of Codable are written by hand below, so
    // nothing is synthesized to derive these from.
    enum CodingKeys: String, CodingKey {
        case name, output, pack, sections
    }

    init(name: String, output: String, sections: [OfficialBinderSection], pack: Bool = false) {
        self.name = name
        self.output = output
        self.sections = sections
        self.pack = pack
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        output = try container.decode(String.self, forKey: .output)
        sections = try container.decode([OfficialBinderSection].self, forKey: .sections)
        pack = try container.decodeIfPresent(Bool.self, forKey: .pack) ?? false
    }

    /// Writes the keys in the order `binders.yaml` is read in — name, output,
    /// pack, sections — rather than the order they are declared in, and omits
    /// `pack:` where it is off, so a regenerated file reads as the hand-written
    /// ones do. The synthesized encoding would put `pack: false` after the
    /// sections, which is both noisier and further from the shape of the file.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(output, forKey: .output)
        if pack { try container.encode(true, forKey: .pack) }
        try container.encode(sections, forKey: .sections)
    }
}

// MARK: - OfficialBinderSection

/// A titled run of tunes within an official binder.
struct OfficialBinderSection: Codable, Sendable {

    /// The title printed on the section's title page. One line written as a
    /// string, or several written as a list and engraved as a stacked block.
    ///
    /// Empty only on a `toc:` section, where the title is the heading over the
    /// listing and a section that wants the default heading writes none.
    /// `BinderDefinitionLoader` rejects every other section without one.
    let title: BinderTitle

    /// Ordered tunes in this section.
    ///
    /// Omitted or empty means the section is a title page and nothing else
    /// (#46) — which is how `binders.yaml` writes a binder cover, and how it
    /// puts two title pages on consecutive pages.
    let entries: [OfficialBinderEntry]

    /// The table of contents this section is (#47), or `nil` when it is not one.
    ///
    /// ```yaml
    /// sections:
    ///   - title: ["SVPB Music", "2027"]   # the cover
    ///   - toc: true                       # the contents, headed "Contents"
    ///   - title: "G4 Tunes"
    ///     entries: [...]
    /// ```
    let toc: TableOfContentsSpec?

    // Spelled out for the same reason as `OfficialBinder.CodingKeys`, and in the
    // order `encode(to:)` writes them.
    enum CodingKeys: String, CodingKey {
        case title, toc, entries
    }

    init(title: BinderTitle = BinderTitle([]), entries: [OfficialBinderEntry] = [],
         toc: TableOfContentsSpec? = nil) {
        self.title = title
        self.entries = entries
        self.toc = toc
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(BinderTitle.self, forKey: .title) ?? BinderTitle([])
        entries = try container.decodeIfPresent([OfficialBinderEntry].self, forKey: .entries) ?? []
        toc = try TableOfContentsSpec.decode(from: container, forKey: .toc)
    }

    /// Writes **title, toc, entries**, omitting each where it says nothing, so a
    /// section comes back out in the shape it went in as.
    ///
    /// A contents page with the default heading stays the `- toc: true`
    /// shorthand rather than growing a blank title, and a title page writes no
    /// `entries:` key rather than an empty list — which is what the decoder
    /// above reads as "a title page and nothing else" (#46). The synthesized
    /// encoding would give title, entries, toc and none of that.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !title.lines.isEmpty { try container.encode(title, forKey: .title) }
        try container.encodeIfPresent(toc, forKey: .toc)
        if !entries.isEmpty { try container.encode(entries, forKey: .entries) }
    }
}

// MARK: - OfficialBinderEntry

/// One tune in an official binder.
struct OfficialBinderEntry: Codable, Sendable {

    /// Tune slug: the `.abc` filename without its extension, matching `Tune.slug`.
    let tune: String

    /// The parts to include, or `nil` for every part.
    ///
    /// Per-part rendering is deferred past MVP (#20), so assembly ignores this.
    /// It is still decoded and stored rather than dropped, so a file written
    /// today keeps its meaning when part selection lands.
    let parts: [String]?

    /// `break: before` where this tune must open a page of its own, whatever the
    /// binder's `pack:` says; `nil` where it may share one (#48).
    let pageBreak: BinderPageBreak?

    init(tune: String, parts: [String]? = nil, pageBreak: BinderPageBreak? = nil) {
        self.tune = tune
        self.parts = parts
        self.pageBreak = pageBreak
    }

    enum CodingKeys: String, CodingKey {
        case tune, parts
        case pageBreak = "break"
    }
}

// MARK: - Assembly

extension OfficialBinder {

    /// This binder as the `BinderSpec` the assembler builds from.
    ///
    /// Official and personal binders are assembled by the same code — the pages, the
    /// title page ahead of each titled section, and the re-engraved page numbers are the
    /// same problem either way — so `binders.yaml`'s shape is mapped onto the personal
    /// spec rather than duplicating `BinderService`.
    ///
    /// Every section of an official binder that is not a table of contents has a title,
    /// so every one of those gets a title page; a `toc:` section's title is the heading
    /// over its listing instead, and it may have none.
    /// Entries carry **no parts**: per-part rendering is deferred past MVP (#20), and an
    /// empty `parts` list is how a spec asks for the tune's one set of pages. Honouring
    /// `parts:` today would repeat the whole score once per named part, since every
    /// `Part` row of a tune points at the same `svgPaths`. When #20 lands, this is where
    /// `entry.parts` starts being passed through.
    func spec(branch: String) -> BinderSpec {
        BinderSpec(
            name: name,
            branch: branch,
            sections: sections.map { section in
                BinderSection(
                    title: section.title.isEmpty ? nil : section.title,
                    entries: section.entries.map {
                        BinderEntry(tuneSlug: $0.tune, parts: [], pageBreak: $0.pageBreak)
                    },
                    toc: section.toc
                )
            },
            pack: pack
        )
    }
}
