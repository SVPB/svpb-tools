import CeolKitSVGRenderer
import Foundation

// MARK: - TableOfContentsRenderer

/// Renders a binder's table of contents: a heading, then one line per thing the
/// binder holds, each naming it and the page it starts on (#47).
///
/// A line is a name flush left, a page number flush right, and a run of spaced
/// periods filling the gap between them. Tunes are set one indent in from the
/// section they sit under, so the listing reads as the binder's shape rather
/// than as a flat list:
///
/// ```
/// Contents
///
/// G4 Tunes .....................................   2
///     G4 Medley ................................   3
///     Scotland the Brave .......................   9
/// ```
///
/// The numbers right-align on one margin however many digits they carry, which
/// is why each is measured and placed at `right - advanceWidth` rather than
/// drawn from a fixed left edge.
///
/// ## Outlines, like every other page
///
/// Every glyph is a `<path>`, for the reason `TitlePageRenderer` gives: no
/// non-browser rasteriser honours `@font-face`, and on Linux `rsvg-convert`
/// resolves `<text>` through whatever fonts the host happens to have. The text
/// goes through `TextOutliner` (CeolKit 1.5.0, sbeitzel/CeolKit#146) in the same
/// face the engraver sets tune titles in, so the contents page belongs to the
/// same document as the pages it lists.
///
/// ## Pagination
///
/// How many pages a listing runs to has to be known *before* any of it is
/// drawn, because the contents pages are themselves pages and every number
/// after them counts them. So the capacity of a page is a property of the
/// layout rather than of the text on it: ``pageCount(forEntries:)`` answers from
/// the entry count alone, `BinderService` reserves that many slots, and
/// ``render(heading:entries:pageCount:)`` fills exactly the slots reserved. The
/// heading sits on the first page only, which is why that page holds fewer
/// lines than the ones after it.
struct TableOfContentsRenderer: Sendable {

    /// One line of the listing.
    struct Entry: Sendable, Equatable {

        /// The name printed flush left: a section's title, or a tune's.
        let text: String

        /// What tells this line apart from others with the same ``text`` — a
        /// tune's further `T:` lines, such as "Harmony 1" (#68). Printed after the
        /// name as `Title / Subtitle` when the line has room for both, and left
        /// off when it has not. Sections have none.
        let subtitle: String?

        /// How far the line is indented, in steps of ``indent``. Sections sit at
        /// 0 and the tunes under them at 1 — or at 0 themselves, in a listing
        /// that names no sections for them to sit under.
        let level: Int

        /// The binder page this thing starts on, printed flush right.
        let page: Int

        init(text: String, subtitle: String? = nil, level: Int, page: Int) {
            self.text = text
            self.subtitle = subtitle
            self.level = level
            self.page = page
        }

        /// The name as one string, the way the line prints it when it fits.
        var name: String {
            subtitle.map { "\(text) / \($0)" } ?? text
        }
    }

    /// One rendered page, and the lines that landed on it.
    ///
    /// The entries come back with the page because a contents page is the one
    /// page in a binder whose meaning is not readable from what it draws: every
    /// glyph on it is a `<path>`, so nothing downstream — a test, a log — can
    /// tell what it says from the SVG alone.
    ///
    /// So they are the entries *as printed*, not as asked for: a subtitle with no
    /// room on its line comes back as `nil`, and a name that had to be cut comes
    /// back cut (#68).
    struct Page: Sendable {
        let svg: String
        let entries: [Entry]
    }

    /// The heading over a listing whose section declares none.
    static let defaultHeading = "Contents"

    /// Portrait letter, whatever the tunes it lists do. A binder carries mixed page sizes
    /// because `%%landscape` is the tune's to set (#62); a contents page is prose and is set
    /// the way a book's is.
    private let pageSize = PageSize.letter

    /// The face CeolKit sets tune titles in, so a contents page and a tune page
    /// are visibly the same document.
    private let face = CeolKitFonts.Face.libertinusSerifRegular

    /// The margin on all four sides. One inch, as a book's front matter is set.
    private let margin = 72.0

    /// The heading's em size, and the space between its baseline and the first
    /// entry's.
    private let headingFontSize = 24.0
    private let headingGap = 30.0

    /// The entries' em size and baseline-to-baseline distance.
    private let entryFontSize = 12.0
    private let lineHeight = 18.0

    /// How far one level of indent moves a line right.
    private let indent = 18.0

    /// The space left either side of the leader, so the dots touch neither the
    /// name nor the number.
    private let leaderGap = 4.0

    /// The least space left between a name and its page number. A name with no
    /// room for this much is shortened until it has.
    private let minimumSeparation = 12.0

    /// The fewest periods that read as a leader. A gap with room for fewer gets
    /// none at all.
    private let minimumLeaderDots = 2

    /// What a shortened name ends in.
    private let ellipsis = "…"

    // MARK: - Pagination

    /// How many entries the first page holds — fewer, because the heading is on it.
    var linesOnFirstPage: Int { capacity(from: margin + headingFontSize + headingGap) }

    /// How many entries every page after the first holds.
    var linesOnLaterPages: Int { capacity(from: margin + entryFontSize) }

    /// How many pages a listing of `count` entries runs to.
    ///
    /// Always at least one: a binder that declares a table of contents gets one,
    /// even when everything it would have listed failed to resolve.
    func pageCount(forEntries count: Int) -> Int {
        guard count > linesOnFirstPage else { return 1 }
        let overflow = Double(count - linesOnFirstPage) / Double(linesOnLaterPages)
        return 1 + Int(overflow.rounded(.up))
    }

    /// How many baselines fit between `top` and the bottom margin.
    private func capacity(from top: Double) -> Int {
        max(1, Int((pageSize.height - margin - top) / lineHeight) + 1)
    }

    // MARK: - Rendering

    /// Returns exactly `pageCount` complete `<svg>` documents listing `entries`.
    ///
    /// `pageCount` is what the caller reserved, so it is what comes back: a
    /// listing that shrank between reserving and drawing — a title page that
    /// failed to render takes its own line with it — ends on a page with room
    /// to spare rather than renumbering the whole binder.
    func render(heading: String, entries: [Entry], pageCount: Int) throws -> [Page] {
        var remaining = entries[...]
        var pages: [Page] = []
        for index in 0 ..< max(1, pageCount) {
            let capacity = index == 0 ? linesOnFirstPage : linesOnLaterPages
            let onThisPage = Array(remaining.prefix(capacity))
            remaining = remaining.dropFirst(onThisPage.count)
            pages.append(try page(heading: index == 0 ? heading : nil, entries: onThisPage))
        }
        return pages
    }

    /// A page carrying nothing, for a reserved slot whose listing could not be drawn.
    ///
    /// The slot was counted into every page number after it, so it has to stay a
    /// page. A blank one is a binder with an unhelpful contents page; dropping it
    /// would be a binder whose every printed number is one too high.
    func blankPage() -> Page {
        Page(svg: document(body: []), entries: [])
    }

    /// One page: its heading, if it is the first, and its share of the entries.
    private func page(heading: String?, entries: [Entry]) throws -> Page {
        var body: [String] = []
        var printed: [Entry] = []
        var baseline: Double

        if let heading {
            let text = try TextOutliner.outline(heading, face: face, fontSize: headingFontSize)
            if !text.svg.isEmpty {
                body.append(place(text.svg, x: margin, y: margin + headingFontSize))
            }
            baseline = margin + headingFontSize + headingGap
        } else {
            baseline = margin + entryFontSize
        }

        for entry in entries {
            let line = try line(entry, baseline: baseline)
            body.append(contentsOf: line.drawn)
            printed.append(line.printed)
            baseline += lineHeight
        }
        return Page(svg: document(body: body), entries: printed)
    }

    /// One entry's name, leader, and page number, all on `baseline`, and the
    /// entry as it was printed.
    private func line(_ entry: Entry, baseline: Double) throws -> (drawn: [String], printed: Entry) {
        let number = try TextOutliner.outline(String(entry.page), face: face, fontSize: entryFontSize)
        let numberX = pageSize.width - margin - number.advanceWidth
        let nameX = margin + Double(max(0, entry.level)) * indent
        let printed = try fitted(entry, toFit: numberX - minimumSeparation - nameX)

        let name = try TextOutliner.outline(printed.name, face: face, fontSize: entryFontSize)

        var drawn: [String] = []
        if !name.svg.isEmpty {
            drawn.append(place(name.svg, x: nameX, y: baseline))
        }
        if let leader = try leader(from: nameX + name.advanceWidth + leaderGap,
                                   to: numberX - leaderGap) {
            drawn.append(place(leader.svg, x: leader.x, y: baseline))
        }
        if !number.svg.isEmpty {
            drawn.append(place(number.svg, x: numberX, y: baseline))
        }
        return (drawn, printed)
    }

    /// `entry` as its line has room to print it in `width`.
    ///
    /// The subtitle goes on only if title and subtitle fit whole. Otherwise it is
    /// dropped and the title alone is shortened as any long name is: a subtitle
    /// is what tells variants of one tune apart, but a line that cannot hold the
    /// title has no room to tell anything apart with (#68). The alternative —
    /// keeping the subtitle and cutting the title to make room for it — is left
    /// until a real binder shows it is needed.
    ///
    /// Never wraps: the line height is what ``pageCount(forEntries:)`` counts
    /// pages by, and it counted them before any name was measured.
    private func fitted(_ entry: Entry, toFit width: Double) throws -> Entry {
        if entry.subtitle != nil, width > 0,
           try TextOutliner.width(of: entry.name, face: face, fontSize: entryFontSize) <= width {
            return entry
        }
        return Entry(text: try shortened(entry.text, toFit: width), subtitle: nil,
                     level: entry.level, page: entry.page)
    }

    /// The run of spaced periods filling `from`…`to`, right-aligned on `to` so
    /// every line's leader stops the same distance short of its number.
    ///
    /// `nil` where there is no room for a run of at least ``minimumLeaderDots``,
    /// which is what a name long enough to reach its own page number leaves: one
    /// stray period between a cut name and its number reads as a typo rather
    /// than as a leader.
    private func leader(from: Double, to: Double) throws -> (svg: String, x: Double)? {
        guard to > from else { return nil }
        let pitch = try TextOutliner.width(of: ". ", face: face, fontSize: entryFontSize)
        let space = try TextOutliner.width(of: " ", face: face, fontSize: entryFontSize)
        guard pitch > space else { return nil }

        // The run has no trailing space, so it is one space shorter than its
        // periods' pitch would suggest — which is the room the last one needs.
        let count = Int((to - from + space) / pitch)
        guard count >= minimumLeaderDots else { return nil }

        let dots = try TextOutliner.outline(
            Array(repeating: ".", count: count).joined(separator: " "),
            face: face, fontSize: entryFontSize)
        return (dots.svg, to - dots.advanceWidth)
    }

    /// `text`, shortened until it fits `width`.
    ///
    /// A name too long for its line is cut rather than shrunk or wrapped: one
    /// size down the whole listing keeps the column of numbers meaning what it
    /// says, and a wrapped name would put a number beside the wrong line. What
    /// is cut ends in an ellipsis, so a shortened name says that it is one.
    func shortened(_ text: String, toFit width: Double) throws -> String {
        guard width > 0 else { return "" }
        guard try TextOutliner.width(of: text, face: face, fontSize: entryFontSize) > width else {
            return text
        }
        var kept = Array(text)
        while !kept.isEmpty {
            kept.removeLast()
            let candidate = String(kept).trimmingCharacters(in: .whitespaces) + ellipsis
            if try TextOutliner.width(of: candidate, face: face, fontSize: entryFontSize) <= width {
                return candidate
            }
        }
        return ""
    }

    // MARK: - SVG

    /// An outlined run, positioned with its pen origin at (`x`, `y`).
    private func place(_ svg: String, x: Double, y: Double) -> String {
        "  <g transform=\"translate(\(fmt(x)) \(fmt(y)))\">\n\(svg)\n  </g>"
    }

    /// `body` wrapped in a letter-sized document.
    private func document(body: [String]) -> String {
        let width = fmt(pageSize.width)
        let height = fmt(pageSize.height)
        return ([
            // Points, for the reason `TitlePageRenderer` gives at the same line: an
            // unqualified 612 is 612 CSS pixels, and the conversion takes each page from
            // what its own SVG declares (#62).
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(width) \(height)\""
                + " width=\"\(width)pt\" height=\"\(height)pt\">",
            "  <g class=\"table-of-contents\">",
        ] + body + [
            "  </g>",
            "</svg>",
        ]).joined(separator: "\n")
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
