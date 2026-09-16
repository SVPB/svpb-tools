import CeolKitParser
import CeolKitSVGRenderer
import Foundation

// MARK: - DividerPageRenderer

/// Renders the divider page that stands ahead of a titled binder section.
///
/// A divider page is one SVG page carrying nothing but the section title, set
/// large and centred a little above the middle of the page. It is fed to
/// `SVGPDFConverter` as an `SVGSource.string` between the pages of the tunes
/// either side of it.
///
/// The title is engraved by CeolKit rather than written as an SVG `<text>`
/// element. Tune pages carry every glyph as a `<path>` outline for a reason —
/// no non-browser rasteriser honours `@font-face`, and on Linux `rsvg-convert`
/// resolves `<text>` through whatever fonts the host happens to have — and a
/// divider page has to hold to the same contract or it would be the one page
/// in the binder set in a substitute face. CeolKit exposes no text-to-outline
/// API, but a tune with a title and no music engraves to exactly that: a single
/// page with the title in Libertinus Serif outlines, centred across the top.
/// This type renders that page, then moves the title down the page and enlarges it.
///
/// Personal binders use this today; official binder assembly (#18) inserts the
/// same page ahead of each `binders.yaml` section.
struct DividerPageRenderer: Sendable {

    enum Failure: Error, CustomStringConvertible {
        /// The title has nothing left to draw once it is made safe for ABC.
        case emptyTitle
        /// CeolKit's output no longer has the shape this type rearranges.
        case unrecognisedRendererOutput(String)

        var description: String {
            switch self {
            case .emptyTitle:
                return "Divider title is empty"
            case .unrecognisedRendererOutput(let detail):
                return "CeolKit title page has an unexpected shape: \(detail)"
            }
        }
    }

    /// Letter, to match the tune pages `BuildService` renders.
    private let config = SVGRenderConfig(pageSize: .letter)

    /// The largest the title is ever drawn, as a multiple of CeolKit's tune-title
    /// size (18pt), so a short title reads as a heading rather than a poster.
    private let maximumScale = 2.5

    /// The widest the title is allowed to become, as a fraction of the page
    /// width. Long titles shrink to fit this rather than running off the page.
    private let maximumWidthFraction = 0.76

    /// Where the title's baseline sits, as a fraction of the page height.
    private let baselineFraction = 0.42

    /// Returns one complete `<svg>` document for a divider page titled `title`.
    func render(title: String) throws -> String {
        let abcTitle = Self.abcSafe(title)
        guard !abcTitle.isEmpty else { throw Failure.emptyTitle }

        let parsed = CeolKitParser().parse("X:1\nT:\(abcTitle)\nK:none\n", options: .default)
        let pages = try SVGRenderer(config: config).render(parsed.score)
        guard pages.count == 1, let page = pages.first else {
            throw Failure.unrecognisedRendererOutput("expected 1 page, got \(pages.count)")
        }
        return try recentre(page)
    }

    // MARK: - ABC

    /// Makes `title` safe to place on a single `T:` line.
    ///
    /// - Line breaks and other control characters would end the field and let the
    ///   rest of the title be read as ABC, so every run of whitespace collapses to
    ///   one space.
    /// - `%` starts a comment. ABC 2.2 escapes it as `\%`, but CeolKit (1.4.0)
    ///   honours no escape and ends the field at the first `%` regardless, and
    ///   Libertinus Serif has no look-alike to substitute (the full-width and
    ///   Arabic percent signs both come out as `.notdef`). It is spelled out
    ///   instead, which is the one form that reaches the page intact. Revisit
    ///   when sbeitzel/CeolKit#145 is fixed; `testCeolKitStillIgnoresTheEscapedPercent`
    ///   fails once it is.
    static func abcSafe(_ title: String) -> String {
        title
            .replacing(/[\s\p{Cc}]+/, with: " ")
            .replacing(/\s*%/, with: " percent")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Layout

    /// Wraps the drawing on CeolKit's title page in a group that moves the title
    /// from the top of the page to the divider position and scales it up.
    ///
    /// CeolKit centres a title horizontally, so the title's width follows from
    /// how far left of centre its first glyph starts; scaling about the centre
    /// line keeps it centred.
    private func recentre(_ page: String) throws -> String {
        guard let defsEnd = page.firstRange(of: "</defs>"),
              let svgEnd = page.ranges(of: "</svg>").last else {
            throw Failure.unrecognisedRendererOutput("no </defs> or </svg>")
        }

        let origins = page.matches(of: /<use\b[^>]*\btransform="translate\(([-0-9.]+) ([-0-9.]+)\)/)
            .compactMap { match -> (x: Double, y: Double)? in
                guard let x = Double(match.1), let y = Double(match.2) else { return nil }
                return (x, y)
            }
        guard let baseline = origins.first?.y, let left = origins.map(\.x).min() else {
            throw Failure.unrecognisedRendererOutput("no glyphs drawn")
        }

        let width = config.pageSize.width
        let centre = width / 2
        let titleWidth = max(2 * (centre - left), 1)
        let scale = min(maximumScale, width * maximumWidthFraction / titleWidth)
        let targetBaseline = config.pageSize.height * baselineFraction

        let transform = "translate(\(fmt(centre)) \(fmt(targetBaseline))) "
            + "scale(\(fmt(scale))) "
            + "translate(\(fmt(-centre)) \(fmt(-baseline)))"

        return String(page[..<defsEnd.upperBound])
            + "\n<g class=\"divider-title\" transform=\"\(transform)\">"
            + String(page[defsEnd.upperBound..<svgEnd.lowerBound])
            + "</g>\n"
            + String(page[svgEnd.lowerBound...])
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
