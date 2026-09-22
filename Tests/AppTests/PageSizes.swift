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
/// it says what the PDF will be without opening the PDF.
///
/// Only `pt` is understood, which is deliberate: a unitless length is a CSS pixel, and a
/// page that states its size in pixels is the #62 bug, not a case to be lenient about.
func declaredPageSize(ofSVG svg: String) -> PDFPageSize? {
    guard let match = svg.firstMatch(of: /<svg[^>]*?width="([\d.]+)pt"\s+height="([\d.]+)pt"/),
          let width = Double(match.1), let height = Double(match.2) else { return nil }
    return PDFPageSize(width: width, height: height)
}

/// The media box of every page of `pdf`, in order.
///
/// Both of SVGPDFKit's backends write one `/Type /Page` dictionary per page carrying that
/// page's `/MediaBox`, but only CoreGraphics writes them where they can be read: librsvg's
/// cairo backend writes PDF 1.5, with its objects inside compressed `/ObjStm` streams. So a
/// file that yields nothing on the first pass is handed to `qpdf` and read again.
///
/// Only page dictionaries count. CoreGraphics also records a document-level default media
/// box, which is the size of no particular page and would have a one-page landscape PDF
/// report a second, portrait one.
///
/// Comes back empty where the objects are compressed and `qpdf` is not installed;
/// `pdfPageSizesOrSkip` is the form to use in a test.
func pdfPageSizes(_ pdf: Data) -> [PDFPageSize] {
    let direct = pageSizes(inPDFBytes: pdf)
    if !direct.isEmpty { return direct }
    guard let uncompressed = uncompressedWithQPDF(pdf) else { return [] }
    return pageSizes(inPDFBytes: uncompressed)
}

/// `pdfPageSizes`, skipping the test where the page dictionaries cannot be read at all.
///
/// That is a machine with compressed-object PDFs and no `qpdf`: CI and
/// `Scripts/linux-tests.sh` both install it, so this skips only where someone runs the
/// suite by hand without it. What holds with or without the tool is the page each document
/// declares (`declaredPageSize(ofSVG:)`) and the absence of a `pageSizeMismatch`
/// diagnostic — and since a `nil` `pageSize` makes the media box the declared page, those
/// cover the same contract.
func pdfPageSizesOrSkip(_ pdf: Data) throws -> [PDFPageSize] {
    let sizes = pdfPageSizes(pdf)
    try XCTSkipIf(sizes.isEmpty, """
        This PDF keeps its page dictionaries in compressed object streams — what librsvg's \
        cairo backend writes — and qpdf, which would decompress them, is not on PATH. \
        Install it, or run the suite through Scripts/linux-tests.sh.
        """)
    return sizes
}

// MARK: - Private

/// The media boxes written in plain bytes, which is all of them once the objects are not
/// in compressed streams.
private func pageSizes(inPDFBytes pdf: Data) -> [PDFPageSize] {
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

/// `pdf` with its object streams expanded and its streams uncompressed, or `nil` where
/// `qpdf` is not installed or could not read the file.
private func uncompressedWithQPDF(_ pdf: Data) -> Data? {
    guard let qpdf = executable(named: "qpdf") else { return nil }

    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("page-sizes-\(UUID().uuidString)", isDirectory: true)
    guard (try? FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)) != nil
    else { return nil }
    defer { try? FileManager.default.removeItem(at: directory) }

    let input = directory.appendingPathComponent("in.pdf")
    let output = directory.appendingPathComponent("out.pdf")
    guard (try? pdf.write(to: input)) != nil else { return nil }

    let process = Process()
    process.executableURL = qpdf
    process.arguments = ["--object-streams=disable", "--stream-data=uncompress",
                         input.path, output.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    // Waited on through a semaphore rather than `waitUntilExit()`, which polls a RunLoop
    // whose deadlines are not enforced in a container on Docker Desktop — the hang
    // `Scripts/linux-tests.sh` preloads a shim to avoid. A test helper should not need
    // the shim to be in place to finish.
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    guard (try? process.run()) != nil else { return nil }
    guard finished.wait(timeout: .now() + 60) == .success else {
        process.terminate()
        return nil
    }

    // qpdf exits 3 on warnings it recovered from, and still writes the file.
    guard process.terminationStatus == 0 || process.terminationStatus == 3 else { return nil }
    return try? Data(contentsOf: output)
}

/// The first `name` on `PATH`, or `nil` where there is none.
private func executable(named name: String) -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
    for directory in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}
