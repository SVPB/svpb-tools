import CeolKitSVGRenderer
import Foundation

// MARK: - TitlePageRenderer

/// Renders a title page: one page carrying nothing but text.
///
/// A title page is a page in its own right, not a property of the tunes after it
/// (#46). It may stand ahead of a section, ahead of the whole binder as its
/// cover, or beside another title page — the renderer does not know or care
/// which. It is fed to `SVGPDFConverter` as an `SVGSource.string` between the
/// pages of the tunes either side of it.
///
/// The text is drawn as glyph outlines rather than SVG `<text>`. Tune pages
/// carry every glyph as a `<path>` for a reason — no non-browser rasteriser
/// honours `@font-face`, and on Linux `rsvg-convert` resolves `<text>` through
/// whatever fonts the host happens to have — and a title page has to hold to the
/// same contract or it would be the one page in the binder set in a substitute
/// face. `TextOutliner` (CeolKit 1.5.0, sbeitzel/CeolKit#146) exists for exactly
/// this case: text on a page with no music, outlined in the same face and by the
/// same metrics the engraver lays tune titles out with, so a line measured here
/// and a line engraved in a tune come out the same width.
///
/// ## Layout
///
/// The lines are stacked as a block, centred across the page and set a little
/// above the middle of it. The first line is the largest the page allows, up to
/// ``maximumFontSize``; the rest are set smaller, so "SVPB Music / 2027" reads
/// as a title with a year under it rather than as two titles. A line too wide
/// for the page shrinks until it fits, and the lines after the first shrink
/// together so they stay one size.
///
/// Both personal binders and official binder assembly (#18) use this.
struct TitlePageRenderer: Sendable {

    enum Failure: Error, CustomStringConvertible {
        /// The title has nothing left to draw once its blank lines are dropped.
        case emptyTitle

        var description: String {
            switch self {
            case .emptyTitle:
                return "Title page has no text"
            }
        }
    }

    /// Letter, to match the tune pages `BuildService` renders.
    private let pageSize = PageSize.letter

    /// The face CeolKit sets tune titles in, so a title page and a tune page are
    /// visibly the same document.
    private let face = CeolKitFonts.Face.libertinusSerifRegular

    /// The largest the first line is ever drawn: 2.5× CeolKit's tune-title size
    /// (18pt), so a short title reads as a heading rather than a poster.
    private let maximumFontSize = 45.0

    /// The widest a line is allowed to become, as a fraction of the page width.
    /// Longer lines shrink to fit this rather than running off the page.
    private let maximumWidthFraction = 0.76

    /// Where the block's baselines are centred, as a fraction of the page height.
    /// A single-line title puts its one baseline exactly here.
    private let baselineFraction = 0.42

    /// How large the lines after the first are, relative to the first.
    private let secondaryScale = 0.62

    /// Baseline-to-baseline distance, as a multiple of the lower line's size.
    private let leadingFactor = 1.35

    /// Returns one complete `<svg>` document for a title page reading `title`.
    func render(title: BinderTitle) throws -> String {
        try render(lines: title.pageLines)
    }

    /// Returns one complete `<svg>` document for a title page reading `lines`,
    /// which are expected to be tidied already (`BinderTitle.pageLines`).
    func render(lines: [String]) throws -> String {
        guard !lines.isEmpty else { throw Failure.emptyTitle }

        let sizes = try fontSizes(for: lines)
        let baselines = self.baselines(for: sizes)

        var drawn: [String] = []
        for (index, line) in lines.enumerated() {
            let text = try TextOutliner.outline(line, face: face, fontSize: sizes[index])
            guard !text.svg.isEmpty else { continue }
            let x = (pageSize.width - text.advanceWidth) / 2
            drawn.append("  <g transform=\"translate(\(fmt(x)) \(fmt(baselines[index])))\">")
            drawn.append(text.svg)
            drawn.append("  </g>")
        }
        guard !drawn.isEmpty else { throw Failure.emptyTitle }

        let width = fmt(pageSize.width)
        let height = fmt(pageSize.height)
        return ([
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(width) \(height)\""
                + " width=\"\(width)\" height=\"\(height)\">",
            "  <g class=\"title-page\">",
        ] + drawn + [
            "  </g>",
            "</svg>",
        ]).joined(separator: "\n")
    }

    // MARK: - Layout

    /// The size each line is set at.
    ///
    /// The first line takes as much of the page width as it can up to
    /// ``maximumFontSize``. The rest start at ``secondaryScale`` of that and
    /// shrink together until the widest of them fits, so they stay one size
    /// however uneven their lengths.
    private func fontSizes(for lines: [String]) throws -> [Double] {
        let maximumWidth = pageSize.width * maximumWidthFraction

        /// How wide `line` is at 1pt. Advance scales linearly with the em size,
        /// so this one measurement fits the line at any size.
        func unitWidth(_ line: String) throws -> Double {
            max(try TextOutliner.width(of: line, face: face, fontSize: 1), 0.0001)
        }

        let first = min(maximumFontSize, maximumWidth / (try unitWidth(lines[0])))
        guard lines.count > 1 else { return [first] }

        var rest = first * secondaryScale
        for line in lines.dropFirst() {
            rest = min(rest, maximumWidth / (try unitWidth(line)))
        }
        return [first] + Array(repeating: rest, count: lines.count - 1)
    }

    /// Where each line's baseline sits, with the set of them centred on
    /// ``baselineFraction`` — which leaves a one-line title exactly where it
    /// was before multi-line titles existed.
    private func baselines(for sizes: [Double]) -> [Double] {
        let gaps = sizes.dropFirst().map { $0 * leadingFactor }
        var baseline = pageSize.height * baselineFraction - gaps.reduce(0, +) / 2
        var baselines = [baseline]
        for gap in gaps {
            baseline += gap
            baselines.append(baseline)
        }
        return baselines
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
