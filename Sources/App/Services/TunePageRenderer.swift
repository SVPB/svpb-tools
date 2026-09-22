import CeolKitParser
import CeolKitSVGRenderer
import Foundation

// MARK: - TunePageRenderer

/// Engraves one tune's pages for the position it occupies in an assembled binder.
///
/// Binder-relative page numbering cannot be done after the fact. CeolKit engraves its
/// footer with `SVGRenderConfig.textRendering` at its default `.outlines`, so every
/// glyph leaves the renderer as path geometry and there is no text left for a downstream
/// tool to rewrite; and the runtime image installs no font packages at all (`Dockerfile`,
/// "No font packages"), so nothing downstream could draw a replacement even if it could
/// find one. The number has to be right at the moment CeolKit draws it.
///
/// So a binder re-renders rather than reusing the build's pages. `%%ceolkit:pagenumber`
/// sets the number the first page of a document prints, and this type prepends it to the
/// tune's own ABC before parsing: the third tune of a binder is engraved knowing it opens
/// on page 17. The build pipeline's pages (`Part.svgPaths`) are still what a per-tune PDF
/// is made of — they are simply not what a binder is made of.
///
/// Nothing here dictates the footer. The music repository's shared style sheets do, and both
/// of their page-number tokens follow `%%ceolkit:pagenumber`: `$P`, and `${pagenumber}`, the
/// consumer-substitutable mark CeolKit 1.6 added (sbeitzel/CeolKit#137) whose *default* value
/// is the same number, which is all a binder needs since it is asking CeolKit to draw it.
///
/// A tune whose `%%footer` names neither token is engraved and numbered correctly and simply
/// prints nothing, which no amount of inspecting the rendered pages can distinguish from a
/// footer that prints a number in outlines. So ``Rendering/printsPageNumbers`` is read from
/// the footer template rather than from the output, and the caller reports it rather than
/// passing those pages off as numbered.
struct TunePageRenderer: Sendable {

    /// What one tune contributed to a binder.
    struct Rendering: Sendable {
        /// One complete `<svg>…</svg>` document per page, in order.
        let pages: [String]
        /// Whether every tune on these pages asks for a footer that prints the page number.
        /// False when one of them names neither `$P` nor `${pagenumber}`: the pages are
        /// numbered, they just do not say so.
        let printsPageNumbers: Bool
    }

    /// Letter — the page a tune is engraved on when its own source does not say otherwise.
    ///
    /// This is a default, not a promise. `%%landscape` in the ABC wins, per tune, and most
    /// of the band's tunes set it, so a binder's pages come back in both orientations and
    /// nothing downstream may assume portrait. The PDF conversion takes each page's size
    /// from the page CeolKit engraved (`ConversionOptions.engravedPages(logger:)`), which is
    /// what keeps a landscape tune at full size instead of at 68% of one (#62).
    private let config = SVGRenderConfig(pageSize: .letter)

    /// Engraves the tune at `url`, numbered so its first page prints `firstPageNumber`.
    ///
    /// - Parameters:
    ///   - url: The tune's `.abc` source, as recorded in `Tune.abcPath`.
    ///   - firstPageNumber: The binder page this tune opens on. Must be at least 1 —
    ///     `%%ceolkit:pagenumber` rejects anything less and the document would fall back
    ///     to numbering from 1.
    ///   - label: The name of the binder section the tune sits in, for a `${label}`
    ///     footer mark to print (#67), or `nil` where the section has no title.
    func render(abcAt url: URL, firstPageNumber: Int, label: String? = nil) throws -> Rendering {
        let abc = try String(contentsOf: url, encoding: .utf8)

        // The parser's base directory is the ABC file's own directory so `I:abc-include`
        // references resolve relative to the source file, exactly as they do in the build.
        let parser = CeolKitParser(
            for: url.deletingLastPathComponent(),
            fileResolver: CeolKitParser.defaultFileResolver
        )
        let parsed = parser.parse(Self.numbering(abc, from: firstPageNumber, label: label),
                                  options: .default)
        let pages = try SVGRenderer(config: config).render(parsed.score)

        // `tune.footer ?? score.footer` is the template one tune's pages print, per
        // CeolKit's own rule for `%%footer` scope. A file of several tunes has to satisfy
        // all of them before its pages can be called numbered.
        let templates = parsed.score.tunes.map { $0.footer ?? parsed.score.footer }
        return Rendering(
            pages: pages,
            printsPageNumbers: !templates.isEmpty && templates.allSatisfy(Self.printsAPageNumber)
        )
    }

    /// Whether a `%%footer` template asks for the page number at all.
    ///
    /// Two tokens do, and `%%ceolkit:pagenumber` moves both: `$P`, and the `${pagenumber}`
    /// mark, whose name CeolKit matches without regard to case. A template naming neither —
    /// and `%%footer ""`, which suppresses a footer rather than inheriting one — prints no
    /// number however the document is numbered.
    static func printsAPageNumber(_ template: String?) -> Bool {
        guard let template else { return false }
        return template.contains("$P") || template.contains(/\$\{[Pp][Aa][Gg][Ee][Nn][Uu][Mm][Bb][Ee][Rr]\}/)
    }

    // MARK: - ABC

    /// `abc` with `%%ceolkit:pagenumber <pageNumber>` — and, where the tune's binder
    /// section has a name, `%%ceolkit:label` — added to its preamble.
    ///
    /// The directives go *after* a leading `%abc` version line, which the standard
    /// requires to be the first line of a file, and before everything else. CeolKit reads
    /// the page number out of the first tune's directive list — into which the parser folds
    /// the preamble in source order — and takes the last one it finds, and a file header's
    /// label is likewise the last one written; so putting ours first means a tune that sets
    /// its own page number or label still wins, as its author meant.
    static func numbering(_ abc: String, from pageNumber: Int, label: String? = nil) -> String {
        var directives = "%%ceolkit:pagenumber \(max(1, pageNumber))\n"
        if let label { directives += labelDirective(label) + "\n" }
        guard abc.hasPrefix("%abc"), let versionLineEnd = abc.firstIndex(of: "\n") else {
            return directives + abc
        }
        let rest = abc.index(after: versionLineEnd)
        return abc[...versionLineEnd] + directives + abc[rest...]
    }

    /// The `%%ceolkit:label` line that makes a `${label}` footer mark print `label` (#67).
    ///
    /// The name is written between quotes and otherwise exactly as given, `"` and all.
    /// CeolKit strips one enclosing pair and keeps everything between them verbatim, so an
    /// inner quote needs no escaping — and a backslash written to escape it would be
    /// printed. The quotes are what keep a name's own leading or trailing quote from being
    /// taken for the enclosing pair.
    static func labelDirective(_ label: String) -> String {
        "%%ceolkit:label \"\(label)\""
    }
}
