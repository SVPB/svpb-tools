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
///       - title: "Grade 4 Tunes"
///         entries:
///           - tune: g4_medley_2026
///           - tune: Moonstar
///             parts: ["Melody", "Seconds"]
/// ```
///
/// This is a different type from the personal `BinderSpec` on purpose: entries
/// here say `tune:`, not `tune_slug:`, `parts` is optional, and every section
/// has a title.
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

    /// Ordered sections, each introduced by a divider page.
    let sections: [OfficialBinderSection]
}

// MARK: - OfficialBinderSection

/// A titled run of tunes within an official binder.
struct OfficialBinderSection: Codable, Sendable {

    /// The title printed on the section's divider page.
    let title: String

    /// Ordered tunes in this section.
    let entries: [OfficialBinderEntry]
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
