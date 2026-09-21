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
///     sections:
///       - title: ["SVPB Music", "2026"]   # front matter: a title page, no tunes
///       - toc: true                      # the table of contents (#47)
///       - title: "Grade 4 Tunes"
///         entries:
///           - tune: g4_medley_2026
///           - tune: Moonstar
///             parts: ["Melody", "Seconds"]
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
                    entries: section.entries.map { BinderEntry(tuneSlug: $0.tune, parts: []) },
                    toc: section.toc
                )
            }
        )
    }
}
