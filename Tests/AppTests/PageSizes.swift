import Foundation
import XCTest

// MARK: - Page sizes

/// One page's size, in points.
struct PDFPageSize: Equatable, CustomStringConvertible {
    let width: Double
    let height: Double

    var isLandscape: Bool { width > height }

    var description: String {
        String(format: "%g × %g pt", width, height)
    }
}

/// The page an SVG document declares for itself, read off its root `<svg>`.
///
/// This is the size `ConversionOptions.pageSize == nil` binds the page at, so asserting on
/// it says what the PDF will be without needing to read the PDF — which matters because
/// the PDF can only be read on one of the two backends (see `pdfPageSizes`).
///
/// Only `pt` is understood, which is deliberate: a unitless length is a CSS pixel, and a
/// page that states its size in pixels is the #62 bug, not a case to be lenient about.
func declaredPageSize(ofSVG svg: String) -> PDFPageSize? {
    guard let match = svg.firstMatch(of: /<svg[^>]*?width="([\d.]+)pt"\s+height="([\d.]+)pt"/),
          let width = Double(match.1), let height = Double(match.2) else { return nil }
    return PDFPageSize(width: width, height: height)
}

/// The media box of every page of `pdf`, in order, or `[]` where the file does not say in
/// plain bytes.
///
/// CoreGraphics writes one uncompressed `/Type /Page` dictionary per page, each carrying
/// that page's `/MediaBox`, which is what this reads. Only page dictionaries count:
/// CoreGraphics also records a document-level default media box, which is the size of no
/// particular page and would have a one-page landscape PDF report a second, portrait one.
///
/// librsvg's cairo backend — SVGPDFKit's Linux path — writes PDF 1.5 with its objects
/// inside compressed `/ObjStm` streams, so there is nothing to match and this comes back
/// empty rather than wrong. `pdfPageSizesOrSkip` is the form to use in a test.
func pdfPageSizes(_ pdf: Data) -> [PDFPageSize] {
    // Latin-1 maps every byte to exactly one scalar and never fails, so the ASCII object
    // dictionaries survive the binary content streams between them.
    guard let text = String(data: pdf, encoding: .isoLatin1) else { return [] }

    return text.components(separatedBy: " obj").compactMap { object in
        // `/Type /Pages` is the page tree, not a page.
        guard object.contains(/\/Type\s*\/Page(?![s\w])/) else { return nil }
        guard let box = object.firstMatch(
            of: /\/MediaBox\s*\[\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*\]/
        ) else { return nil }
        guard let x0 = Double(box.1), let y0 = Double(box.2),
              let x1 = Double(box.3), let y1 = Double(box.4) else { return nil }
        return PDFPageSize(width: abs(x1 - x0), height: abs(y1 - y0))
    }
}

/// `pdfPageSizes`, skipping the test where the PDF keeps its page dictionaries compressed.
///
/// That is the Linux rsvg-convert path, so an assertion made through this one is checked on
/// Apple and skipped on Linux. What holds on both is the page each document *declares*
/// (`declaredPageSize(ofSVG:)`) and the absence of a `pageSizeMismatch` diagnostic — and
/// since a `nil` `pageSize` makes the media box the declared page, those cover the same
/// contract on the backend this cannot read.
func pdfPageSizesOrSkip(_ pdf: Data) throws -> [PDFPageSize] {
    let sizes = pdfPageSizes(pdf)
    try XCTSkipIf(sizes.isEmpty, """
        This PDF keeps its page dictionaries in compressed object streams, which is what \
        librsvg's cairo backend writes, so its media boxes cannot be read from the bytes. \
        The declared page sizes and the conversion diagnostics are asserted on both backends.
        """)
    return sizes
}
