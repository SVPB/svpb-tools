import Foundation
import SVGPDFKit
import Vapor

// MARK: - Converting engraved pages

extension ConversionOptions {

    /// How this server turns CeolKit's engraved pages into a PDF — the per-tune PDFs a
    /// build writes (`BuildService`) and the binders `BinderService` assembles both go
    /// through these options, because both are handed whole pages that CeolKit has
    /// already laid out.
    ///
    /// Three settings matter, and #62 is what the defaults did without them:
    ///
    /// - **`pageSize` is `nil`** — each PDF page is the page its own SVG declares
    ///   (sbeitzel/SVGPDFKit#5). `%%landscape` is a property of the source, per tune, and
    ///   most of the band's tunes set it, so one page size for a whole document is a guess
    ///   that is wrong for most of it: a `792 × 612` landscape page aspect-fitted onto
    ///   portrait letter came out at 68%, with five blank inches at the foot of every
    ///   landscape sheet. A binder keeps each tune's own orientation, so the page follows
    ///   the engraving rather than the engraving being squeezed into a page chosen here.
    /// - **`margin` therefore does not apply**, which is what we want. The SVG *is* the
    ///   page and carries the margins CeolKit engraved into it; insetting it inside a page
    ///   of its own size could only scale the music down a second time.
    /// - **`injectPageNumbers` is off** — CeolKit numbers the pages it engraves, and
    ///   outlines every glyph doing it, so there is no `<text>` placeholder left for
    ///   SVGPDFKit to rewrite. Asking for one now costs a warning per page
    ///   (sbeitzel/SVGPDFKit#3) for something that never worked and is not wanted.
    ///
    /// Diagnostics go to `logger` rather than to stderr, so that a page whose size had to
    /// be read from its `viewBox` — the one way a document can still be mis-sized here —
    /// lands where the operator reads the rest of the build.
    static func engravedPages(logger: Logger) -> ConversionOptions {
        var options = ConversionOptions()
        options.pageSize = nil
        options.injectPageNumbers = false
        options.diagnosticHandler = DiagnosticHandler { diagnostic in
            logger.warning("[SVGPDFKit] \(diagnostic)")
        }
        return options
    }
}
