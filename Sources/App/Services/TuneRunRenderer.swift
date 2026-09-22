import CeolKitParser
import CeolKitSVGRenderer
import Foundation

// MARK: - TuneRunRenderer

/// Engraves a *run* of consecutive binder tunes as one document, so that two short tunes
/// share a page instead of each taking a whole one (#48).
///
/// `TunePageRenderer` hands CeolKit one tune at a time, which commits every tune to a whole
/// number of pages before assembly ever sees it: a jig that fills a third of a page still
/// arrives as a page. Nothing downstream can recover that space — packing two full-page SVGs
/// onto one sheet would mean laying the music out again. So a binder that asks to be packed
/// re-parses the ABC of a whole run and renders it once, and CeolKit's own packer does the
/// rest: `VerticalLayoutEngine` opens a new page only when the page it is on cannot hold the
/// next tune's title block and first system together.
///
/// A run is a maximal stretch of consecutive tunes with nothing between them that owns a page
/// of its own. `BinderService` decides where runs end — a title page, a table of contents, or
/// an entry asking to start fresh — so a boundary never costs a page that was not being spent
/// anyway.
///
/// ## Concatenating is not appending
///
/// Several `%%ceolkit:` directives are written in a file's *preamble* and are file-scoped, so
/// in a one-tune-per-file world a tune's directives cannot reach its neighbours. Laid end to
/// end they can: a preamble `%%ceolkit:scale 0.85` would resize every tune after it in the
/// run. So each file's preamble is **hoisted into its own tunes' headers**, where ABC v2.2
/// §4.23 scopes it to the tune it was written for and CeolKit honours that scoping
/// (sbeitzel/CeolKit#153). What comes out of a run is what came out of the separate renders,
/// only packed.
///
/// Two things are hoisted with care:
///
/// - **`I:abc-include`** is expanded here rather than left for CeolKit. A blank line in an
///   included style sheet means nothing in the file preamble it was written for, but in a
///   tune header it *ends the header* — so the include's lines are read, its own includes
///   expanded, and its blank lines dropped before they are hoisted.
/// - **`%%landscape`** is a property of a page, so CeolKit only honours a change of
///   orientation at a page boundary the author wrote (sbeitzel/CeolKit#158): a `%%landscape`
///   in a tune header with no `%%newpage` beside it is dropped with a diagnostic. The run
///   therefore states the *first* file's orientation in the document preamble and, wherever a
///   later file disagrees with the one before it, writes `%%newpage` alongside the
///   `%%landscape` in that tune's header. A portrait tune after a landscape one starts a
///   fresh page, which is the only thing it could do.
///
/// ## Page numbers and where a tune landed
///
/// The run opens at the binder page it was given, the same way `TunePageRenderer` numbers one
/// tune, and CeolKit numbers the rest as it lays them out. Which page a tune *started* on is
/// then something only the layout knows and nothing in the emitted SVG says, so this uses
/// `renderDocument(_:)` and reads it back from the placement map
/// (sbeitzel/CeolKit#152) — which is what keeps a table of contents (#47) honest under packing.
struct TuneRunRenderer: Sendable {

    /// One tune of a run: the slug the binder knows it by, and the ABC behind it.
    struct Source: Sendable {
        let slug: String
        let url: URL
    }

    /// What one run contributed to a binder.
    struct Rendering: Sendable {
        /// One complete `<svg>…</svg>` document per page, in order.
        let pages: [String]
        /// Per source, in the order they were handed in: the index into ``pages`` of the
        /// page that source's first tune opens on.
        let starts: [Int]
        /// Whether every tune in the run asks for a footer that prints the page number.
        /// False when one of them names neither `$P` nor `${pagenumber}`: the pages are
        /// numbered, they just do not all say so.
        let printsPageNumbers: Bool
    }

    /// Why a run could not be engraved as one document. Each of these leaves the caller to
    /// fall back to rendering the run's tunes one at a time, which is what a binder that
    /// never asked to be packed does anyway.
    enum Failure: Error, CustomStringConvertible {
        /// A run of nothing is not a run.
        case empty
        /// A source file that holds no tune at all cannot be placed in the run, and the
        /// tunes after it would be read off by one.
        case noTunes(slug: String)
        /// The concatenated document did not parse into the tunes it was built from, so
        /// nothing can be said about which page any of them landed on.
        case tuneCountChanged(expected: Int, parsed: Int)
        /// CeolKit reported a placement per tune and the count did not match.
        case placementsChanged(expected: Int, reported: Int)
        /// The run produced no pages at all.
        case noPages

        var description: String {
            switch self {
            case .empty:
                "a run has to hold at least one tune"
            case .noTunes(let slug):
                "'\(slug)' holds no X: tune to pack"
            case .tuneCountChanged(let expected, let parsed):
                "the run was built from \(expected) tune(s) but parsed as \(parsed)"
            case .placementsChanged(let expected, let reported):
                "the run holds \(expected) tune(s) but CeolKit placed \(reported)"
            case .noPages:
                "the run engraved no pages"
            }
        }
    }

    /// Letter — the page a run is engraved on where its sources do not say otherwise, as in
    /// `TunePageRenderer`.
    ///
    /// The run's own `%%landscape` handling above overrides it, per page, so one run can
    /// produce pages of both orientations. Each goes into the PDF at the size it was
    /// engraved (`ConversionOptions.engravedPages(logger:)`), so a packed run needs no
    /// agreement about orientation between the tunes it packs (#62).
    private let config = SVGRenderConfig(pageSize: .letter)

    // MARK: - Rendering

    /// Engraves `sources` as one packed document, opening at `firstPageNumber`.
    ///
    /// - Parameters:
    ///   - sources: The run's tunes, in binder order. Every one of them contributes at least
    ///     one tune to the document; a source file holding several tunes contributes all of
    ///     them, and ``Rendering/starts`` names the page its *first* one opens on.
    ///   - firstPageNumber: The binder page the run opens on. Must be at least 1 —
    ///     `%%ceolkit:pagenumber` rejects anything less and the document would fall back to
    ///     numbering from 1.
    /// - Throws: ``Failure`` where the run cannot be engraved as one document, and whatever
    ///   reading a source file or rendering threw.
    func render(_ sources: [Source], firstPageNumber: Int) throws -> Rendering {
        guard !sources.isEmpty else { throw Failure.empty }

        let documents = try sources.map {
            Self.takeApart(try String(contentsOf: $0.url, encoding: .utf8),
                           includesRelativeTo: $0.url.deletingLastPathComponent())
        }
        for (source, document) in zip(sources, documents) where document.tunes.isEmpty {
            throw Failure.noTunes(slug: source.slug)
        }
        let expected = documents.reduce(0) { $0 + $1.tunes.count }

        // The base directory is the first source's, for an `I:abc-include` written somewhere
        // this type does not expand — a tune header or body. Every tune of a binder comes
        // from the same branch checkout, so one directory serves the whole run.
        let parser = CeolKitParser(
            for: sources[0].url.deletingLastPathComponent(),
            fileResolver: CeolKitParser.defaultFileResolver
        )
        let parsed = parser.parse(Self.concatenate(documents, firstPageNumber: firstPageNumber),
                                  options: .default)
        // A file that parsed into a different number of tunes than it was cut into is a file
        // this type took apart wrongly, and every placement below would name the wrong tune.
        guard parsed.score.tunes.count == expected else {
            throw Failure.tuneCountChanged(expected: expected, parsed: parsed.score.tunes.count)
        }

        let document = try SVGRenderer(config: config).renderDocument(parsed.score)
        guard document.placements.count == expected else {
            throw Failure.placementsChanged(expected: expected, reported: document.placements.count)
        }
        guard !document.pages.isEmpty else { throw Failure.noPages }

        // The placements are one per tune in score order; a source contributing several tunes
        // is listed at the page its first one opens on.
        var starts: [Int] = []
        var tuneIndex = 0
        for source in documents {
            starts.append(document.placements[tuneIndex].pageIndex)
            tuneIndex += source.tunes.count
        }

        // `tune.footer ?? score.footer` is the template one tune's pages print, per CeolKit's
        // own rule for `%%footer` scope. A run has to satisfy all of them before its pages
        // can be called numbered.
        let templates = parsed.score.tunes.map { $0.footer ?? parsed.score.footer }
        return Rendering(
            pages: document.pages,
            starts: starts,
            printsPageNumbers: !templates.isEmpty && templates.allSatisfy(TunePageRenderer.printsAPageNumber)
        )
    }
}

// MARK: - Taking a file apart

extension TuneRunRenderer {

    /// One `.abc` file, cut into the pieces a run is built from.
    ///
    /// The cut is by `X:`, which is the only line that can open a tune, and everything ahead
    /// of the first one is the file preamble — the directives that a single-file render scopes
    /// to the file and a run has to scope to the file's own tunes instead.
    struct Document: Equatable {

        /// One tune of the file.
        struct Tune: Equatable {
            /// Directive lines standing in the gap *above* this tune — between it and the
            /// tune before it in the same file. Empty for the first tune of a file, whose
            /// gap is the preamble.
            var carried: [String] = []
            /// The tune's own lines, `X:` first.
            var lines: [String]
        }

        /// The `%abc-…` line, where the file carried one. The standard requires it to be the
        /// first line of a file, so a run states it once.
        var versionLine: String?
        /// The preamble as it will be written into each of this file's tune headers:
        /// `I:abc-include` expanded, `%%landscape` taken out, blank lines dropped.
        var hoisted: [String] = []
        /// The orientation the preamble asks for, or `nil` where it states none — in which
        /// case the file takes whatever the run is already in.
        var landscape: Bool?
        /// The file's tunes, in order.
        var tunes: [Tune] = []
        /// Directives written after the last tune, which belong to whatever follows it.
        var trailing: [String] = []
    }

    /// Cuts `abc` into the pieces ``concatenate(_:firstPageNumber:)`` writes back out.
    ///
    /// - Parameter directory: where an `I:abc-include` in the preamble is resolved from,
    ///   which is the source file's own directory exactly as it is in the build.
    static func takeApart(_ abc: String, includesRelativeTo directory: URL) -> Document {
        let lines = abc.replacing(/\r\n?/, with: "\n").split(separator: "\n",
                                                             omittingEmptySubsequences: false)
            .map(String.init)
        var document = Document()

        var index = 0
        if let first = lines.first, first.hasPrefix("%abc") {
            document.versionLine = first
            index = 1
        }

        // The preamble: everything up to the first tune.
        var preamble: [String] = []
        while index < lines.count, !lines[index].hasPrefix("X:") {
            preamble.append(lines[index])
            index += 1
        }
        (document.hoisted, document.landscape) = hoistable(preamble, includesRelativeTo: directory)

        // The tunes, each running to the next `X:`. A tune's trailing run of blank lines and
        // directives is not part of it: a directive written below a tune is written for what
        // comes after it, so it is carried to the next tune rather than left to become a
        // file-global statement about the whole run.
        while index < lines.count {
            var body: [String] = [lines[index]]
            index += 1
            while index < lines.count, !lines[index].hasPrefix("X:") {
                body.append(lines[index])
                index += 1
            }
            var gap: [String] = []
            while let last = body.last, last.hasPrefix("%") || last.trimmed.isEmpty {
                gap.insert(body.removeLast(), at: 0)
                if body.count == 1 { break }   // never eat the `X:` line itself
            }
            document.tunes.append(Document.Tune(carried: document.trailing, lines: body))
            document.trailing = gap.filter { !$0.trimmed.isEmpty }
        }
        return document
    }

    /// Splits a file preamble into the lines that can be written into a tune header and the
    /// orientation it asked for.
    ///
    /// Three kinds of line do not survive the move: blank lines, which end a tune header;
    /// `I:abc-include`, whose file is read here so that *its* blank lines cannot end one
    /// either; and `%%landscape`, which CeolKit only honours beside a page break and which
    /// ``concatenate(_:firstPageNumber:)`` therefore re-states where it can mean something.
    private static func hoistable(_ preamble: [String],
                                  includesRelativeTo directory: URL) -> ([String], Bool?) {
        var hoisted: [String] = []
        var landscape: Bool?
        for line in preamble {
            let trimmed = line.trimmed
            if trimmed.isEmpty { continue }
            if let stated = landscapeValue(of: trimmed) { landscape = stated; continue }
            if let included = includedFile(of: trimmed) {
                hoisted += expanding(included, from: directory, seen: [])
                continue
            }
            hoisted.append(line)
        }
        return (hoisted, landscape)
    }

    /// The lines of an included file, with its own includes expanded and its blank lines
    /// dropped, or the `I:abc-include` line itself where the file cannot be read.
    ///
    /// Leaving the line in place on failure is deliberate: CeolKit resolves it the same way
    /// and reports a missing or unreadable include far better than a silent omission would.
    private static func expanding(_ filename: String, from directory: URL,
                                  seen: Set<URL>) -> [String] {
        let url = directory.appendingPathComponent(filename).standardized
        guard !seen.contains(url),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ["I:abc-include \(filename)"]
        }
        return text.replacing(/\r\n?/, with: "\n").split(separator: "\n").flatMap { line -> [String] in
            let trimmed = line.trimmed
            if trimmed.isEmpty { return [] }
            if let nested = includedFile(of: trimmed) {
                return expanding(nested, from: url.deletingLastPathComponent(),
                                 seen: seen.union([url]))
            }
            return [String(line)]
        }
    }

    /// The filename an `I:abc-include` names, or `nil` where the line is not one.
    ///
    /// `I:` is the standard's spelling (§3.1.19) and the only one CeolKit's own expander
    /// answers to, so it is the only one matched here.
    private static func includedFile(of line: String) -> String? {
        guard let match = line.firstMatch(of: /^I:\s*abc-include\s+(\S.*)$/.ignoresCase()) else {
            return nil
        }
        let filename = String(match.1).trimmed
        return filename.isEmpty ? nil : filename
    }

    /// What a `%%landscape` line asks for, or `nil` where the line is not one — or is one
    /// whose value cannot be read, which is left where it stands for CeolKit to complain about.
    private static func landscapeValue(of line: String) -> Bool? {
        guard let match = line.firstMatch(of: /^%%landscape\b\s*(\S*)/.ignoresCase()) else {
            return nil
        }
        switch String(match.1).lowercased() {
        case "", "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }
}

// MARK: - Putting the run together

extension TuneRunRenderer {

    /// Writes `documents` out as one ABC document, opening at `firstPageNumber`.
    ///
    /// Every tune is renumbered into one sequence, and carries in its own header everything
    /// the file it came from stated about it: its preamble, whatever stood in the gap above
    /// it, and — where the run's orientation has to change for it — a `%%newpage` with the
    /// `%%landscape` that only a page boundary can carry.
    static func concatenate(_ documents: [Document], firstPageNumber: Int) -> String {
        var lines: [String] = []
        if let version = documents.compactMap(\.versionLine).first { lines.append(version) }
        // First, so that a tune stating its own page number still wins — the parser folds the
        // preamble into the first tune's directives in source order and CeolKit takes the last.
        lines.append("%%ceolkit:pagenumber \(max(1, firstPageNumber))")
        // The orientation the document opens in. A `%%landscape` here is not a change, so it
        // needs no page break to stand beside; every later change does.
        if let opening = documents.first?.landscape {
            lines.append("%%landscape \(opening ? 1 : 0)")
        }

        var running = documents.first?.landscape ?? false
        var pending: [String] = []
        var number = 0
        for (index, document) in documents.enumerated() {
            for (position, tune) in document.tunes.enumerated() {
                number += 1
                lines.append("X:\(number)")
                if index > 0, position == 0, let wanted = document.landscape, wanted != running {
                    lines.append("%%newpage")
                    lines.append("%%landscape \(wanted ? 1 : 0)")
                    running = wanted
                }
                // Source order: what the file before this one left behind, then this file's
                // preamble, then the gap this tune sits under.
                lines += pending
                pending = []
                lines += document.hoisted
                lines += tune.carried
                lines += tune.lines.dropFirst()
                lines.append("")
            }
            if let stated = document.landscape { running = stated }
            pending = document.trailing
        }
        // Whatever the last file left below its last tune is a statement about music that
        // never comes, so it is dropped rather than made file-global over the whole run.
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: -

private extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
