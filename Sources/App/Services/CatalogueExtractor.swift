import CeolKitParser
import Foundation

// MARK: - CatalogueExtractor

/// Derives the catalogue fields — tune title and part names — from a CeolKit
/// parse result.
///
/// This performs no parsing of its own. CeolKit owns ABC syntax entirely; this
/// type only maps its `Score` onto the handful of values the `Tune` and `Part`
/// records need. It replaces the hand-rolled `ABCParser` that scanned for `T:`
/// and `V:` lines, which duplicated work `BuildService` was already doing to
/// render the file.
///
/// Deliberately kept free of `import CeolKitModel`: the score model exposes its
/// own `Tune` type, and importing it here would shadow-clash with the Fluent
/// `Tune` model. Values flow through without their types ever being named.
enum CatalogueExtractor {

    /// The catalogue fields for one ABC file.
    struct Entry: Sendable {
        /// Title of the first tune in the file, or nil if it declares none.
        let title: String?
        /// Ordered, deduplicated part names across every tune in the file.
        /// Never empty.
        let parts: [String]
    }

    /// Part name used when a file has nothing but a single unnamed voice — the
    /// musician is looking at a whole score, not one instrument's part.
    static let fullScorePartName = "Full Score"

    /// The voice ID that CeolKit assigns to the synthetic voice it creates for a
    /// tune with no explicit `V:` fields.
    private static let defaultVoiceID = "1"

    static func extract(from parsed: ParseResult) -> Entry {
        Entry(title: title(from: parsed), parts: partNames(from: parsed))
    }

    // MARK: - Title

    /// The first `T:` value in the file.
    ///
    /// A file may hold several tunes (a medley is one ABC file with several `X:`
    /// blocks); the catalogue keys on the filename and builds one PDF per file,
    /// so the first tune's title is what names the entry.
    private static func title(from parsed: ParseResult) -> String? {
        guard let raw = parsed.score.tunes.first?.titles.first?.value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Parts

    /// Every distinct voice across every tune in the file, in first-appearance
    /// order.
    ///
    /// A voice is labelled by its `nm=` name, falling back to its `snm=` short
    /// name and then to the raw voice ID (`V:Bass` with no attributes is simply
    /// "Bass"). The `*` all-voices pseudo-voice is not a real part and is skipped.
    private static func partNames(from parsed: ParseResult) -> [String] {
        var names: [String] = []

        for tune in parsed.score.tunes {
            for voice in tune.voices {
                guard case .named(let voiceID) = voice.id else { continue }
                let properties = voice.properties
                let name = properties.name ?? properties.subname ?? voiceID
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !names.contains(trimmed) else { continue }
                names.append(trimmed)
            }
        }

        // A lone unnamed default voice means the file never declared a `V:` field
        // at all (or declared only `V:1`), so there are no parts to choose
        // between — the whole score is the only thing on offer.
        if names.isEmpty || names == [defaultVoiceID] {
            return [fullScorePartName]
        }
        return names
    }
}
