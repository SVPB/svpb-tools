import Foundation

// MARK: - ABCParser

/// A lightweight ABC notation parser that extracts tune metadata for the catalogue.
///
/// Only `T:` (title) and `V:` (voice/part) header fields are extracted.
/// Full ABC syntax validation is out of scope — the goal is catalogue
/// population, not format validation.
enum ABCParser {

    struct ParsedTune: Sendable {
        /// The first `T:` value found in the file, trimmed of whitespace.
        let title: String?
        /// Ordered, deduplicated list of voice/part names from `V:` fields.
        /// Defaults to `["Full Score"]` when no `V:` fields are present.
        let parts: [String]
    }

    /// Parses an ABC file's text content and returns the extracted title and part names.
    static func parse(_ content: String) -> ParsedTune {
        var title: String?
        var parts: [String] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("T:") {
                if title == nil {
                    let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { title = value }
                }
            } else if trimmed.hasPrefix("V:") {
                let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let partName = extractPartName(from: value)
                if !partName.isEmpty && !parts.contains(partName) {
                    parts.append(partName)
                }
            }
        }

        return ParsedTune(
            title: title,
            parts: parts.isEmpty ? ["Full Score"] : parts
        )
    }

    // MARK: - Private helpers

    /// Extracts a display name from a `V:` field value.
    ///
    /// ABC voice fields can take several forms:
    /// - `1 name="Melody"` — extract the `name=` attribute value
    /// - `Melody` — use the value directly
    /// - `1` — use the numeric ID as-is
    private static func extractPartName(from value: String) -> String {
        // Look for name="..." attribute
        if let nameStart = value.range(of: #"name=""#)?.upperBound {
            let afterName = value[nameStart...]
            if let endQuote = afterName.firstIndex(of: "\"") {
                let name = String(afterName[afterName.startIndex..<endQuote])
                if !name.isEmpty { return name }
            }
        }
        // Fall back to the first whitespace-delimited token (the voice ID)
        return value.components(separatedBy: .whitespaces).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
