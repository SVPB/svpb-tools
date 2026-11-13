import Foundation
import Vapor

// MARK: - ArtworkFormat

/// The image formats artwork may be uploaded in (#89).
enum ArtworkFormat: String, Sendable, CaseIterable {
    case svg, png, ico

    var contentType: String {
        switch self {
        case .svg: "image/svg+xml"
        case .png: "image/png"
        case .ico: "image/x-icon"
        }
    }

    var label: String { rawValue.uppercased() }
}

// MARK: - OrgArtwork

/// What artwork each slot accepts, how an upload is recognised and checked, and the
/// built-in neutral images served when nothing has been uploaded (#89).
enum OrgArtwork {

    /// The most an upload may be: 1 MB.
    static let maxBytes = 1_048_576

    /// The side of the touch icon iOS asks for, in pixels.
    static let touchIconSide = 180

    /// The formats `slot` accepts.
    static func formats(for slot: OrgAsset.Slot) -> [ArtworkFormat] {
        switch slot {
        case .logo:      [.svg, .png]
        case .favicon:   [.svg, .png, .ico]
        case .touchIcon: [.png]
        }
    }

    /// Why an upload was refused, in words that tell an admin what to fix.
    struct Rejection: Error, Equatable, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// Recognises `data` by its content — never by the name or type the browser claims —
    /// and checks it is fit for `slot`.
    ///
    /// - Returns: The format the upload is in, to store and serve it as.
    /// - Throws: ``Rejection``, or ``SVGValidator/Rejection`` for an SVG that is not
    ///   passive drawing.
    static func check(_ data: Data, for slot: OrgAsset.Slot) throws -> ArtworkFormat {
        guard !data.isEmpty else {
            throw Rejection(reason: "The file is empty.")
        }
        guard data.count <= maxBytes else {
            throw Rejection(reason: """
                The file is \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)); \
                artwork may be at most 1 MB.
                """)
        }
        let accepted = formats(for: slot)
        let acceptedList = accepted.map(\.label).joined(separator: " or ")
        guard let format = detect(data) else {
            throw Rejection(reason: "The file is not a PNG, ICO or SVG image. This slot accepts \(acceptedList).")
        }
        guard accepted.contains(format) else {
            throw Rejection(reason: "The file is \(format.label); this slot accepts \(acceptedList).")
        }

        switch format {
        case .svg:
            try SVGValidator.validate(data)
        case .png where slot == .touchIcon:
            guard let size = pngSize(data) else {
                throw Rejection(reason: "The PNG's size could not be read.")
            }
            guard size.width == touchIconSide, size.height == touchIconSide else {
                throw Rejection(reason: """
                    The touch icon must be \(touchIconSide)×\(touchIconSide) pixels; this one \
                    is \(size.width)×\(size.height).
                    """)
            }
        default:
            break
        }
        return format
    }

    /// The format `data` is in, by its first bytes; `nil` when it is none of them.
    static func detect(_ data: Data) -> ArtworkFormat? {
        let bytes = [UInt8](data.prefix(8))
        if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return .png
        }
        // ICONDIR: reserved 0, type 1 (icon), and at least one image.
        if bytes.count >= 6, bytes[0...3] == [0, 0, 1, 0], bytes[4] != 0 || bytes[5] != 0 {
            return .ico
        }
        // Text that has an <svg element somewhere near the start. Whether it really is a
        // usable SVG is the validator's question.
        if let head = String(data: data.prefix(4096), encoding: .utf8)
                ?? String(data: data, encoding: .utf8),
           head.contains("<svg") {
            return .svg
        }
        return nil
    }

    /// A PNG's width and height, from its `IHDR` chunk, which the format requires first.
    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, bytes[12...15] == Array("IHDR".utf8)[...] else { return nil }
        func bigEndian(_ range: ClosedRange<Int>) -> Int {
            bytes[range].reduce(0) { $0 << 8 | Int($1) }
        }
        return (bigEndian(16...19), bigEndian(20...23))
    }

    // MARK: - The built-in images

    /// TNG's neutral artwork, served for a slot with nothing uploaded. Read once at startup
    /// from `Resources/Branding/`, outside `Public/` so `FileMiddleware` never answers for
    /// these paths before the artwork routes do.
    struct Defaults: Sendable {
        let logoSVG: Data
        let faviconSVG: Data
        let faviconICO: Data
        let touchIconPNG: Data

        /// The directory under the resources directory that holds them.
        static let directoryName = "Branding"

        static func load(fromResources resourcesDirectory: String) throws -> Defaults {
            let base = URL(fileURLWithPath: resourcesDirectory, isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
            func read(_ name: String) throws -> Data {
                try Data(contentsOf: base.appendingPathComponent(name))
            }
            return try Defaults(
                logoSVG: read("logo.svg"),
                faviconSVG: read("favicon.svg"),
                faviconICO: read("favicon.ico"),
                touchIconPNG: read("apple-touch-icon.png")
            )
        }
    }
}

// MARK: - Application storage

extension Application {

    private struct DefaultArtworkKey: StorageKey { typealias Value = OrgArtwork.Defaults }

    /// TNG's built-in neutral artwork (#89), loaded in `configure`.
    var defaultArtwork: OrgArtwork.Defaults {
        get { storage[DefaultArtworkKey.self]! }
        set { storage[DefaultArtworkKey.self] = newValue }
    }
}
