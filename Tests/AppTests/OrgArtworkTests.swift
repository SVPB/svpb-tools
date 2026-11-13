import Fluent
import Foundation
import XCTVapor
import XCTest
@testable import App

/// The organisation's artwork: served from the upload when there is one and TNG's own
/// otherwise, always with a sandboxing CSP; uploads checked by content, type and size (#89).
final class OrgArtworkTests: XCTestCase {

    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The head of a PNG of the given size: enough to be recognised and measured.
    static func png(width: Int, height: Int) -> Data {
        func be32(_ v: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) } }
        return Data(pngSignature + be32(13) + Array("IHDR".utf8) + be32(width) + be32(height)
                    + [8, 6, 0, 0, 0] + [0, 0, 0, 0])
    }

    static let ico = Data([0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0])

    static let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>"#.utf8)

    // MARK: - The built-in images

    func testEachRouteServesTheBuiltInImageWithNothingUploaded() async throws {
        let expected: [(String, String, Data)] = [
            ("favicon.ico", "image/x-icon", app.defaultArtwork.faviconICO),
            ("favicon.svg", "image/svg+xml", app.defaultArtwork.faviconSVG),
            ("apple-touch-icon.png", "image/png", app.defaultArtwork.touchIconPNG),
            ("img/logo", "image/svg+xml", app.defaultArtwork.logoSVG),
        ]
        for (path, type, bytes) in expected {
            try await app.test(.GET, path) { res async in
                XCTAssertEqual(res.status, .ok, path)
                XCTAssertEqual(res.headers.first(name: .contentType), type, path)
                XCTAssertEqual(Data(buffer: res.body), bytes, path)
                XCTAssertFalse(bytes.isEmpty, path)
            }
        }
    }

    /// The built-in images are TNG's own, not SVPB's thistle, and pass the same check an
    /// upload would.
    func testTheBuiltInImagesAreNeutralAndValid() throws {
        for data in [app.defaultArtwork.logoSVG, app.defaultArtwork.faviconSVG] {
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("thistle"))
            XCTAssertFalse(text.contains("SVPB"))
            XCTAssertNoThrow(try SVGValidator.validate(data))
        }
        XCTAssertEqual(try OrgArtwork.check(app.defaultArtwork.touchIconPNG, for: .touchIcon), .png)
        XCTAssertEqual(try OrgArtwork.check(app.defaultArtwork.faviconICO, for: .favicon), .ico)
    }

    /// `FileMiddleware` answers before the routes, so nothing in `Public/` may shadow them.
    func testNothingInPublicShadowsTheArtworkRoutes() {
        let publicDirectory = URL(fileURLWithPath: app.directory.publicDirectory)
        for path in ["favicon.ico", "favicon.svg", "apple-touch-icon.png", "img/logo"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: publicDirectory.appendingPathComponent(path).path), path)
        }
    }

    // MARK: - Uploads

    func testAnUploadIsServedInsteadOfTheBuiltInImage() async throws {
        let cookies = try await OrgTestSupport.signInAsAdmin(app)
        try await upload(Self.svg, to: "logo", cookies: cookies, expect: .noContent)

        try await app.test(.GET, "img/logo") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: .contentType), "image/svg+xml")
            XCTAssertEqual(Data(buffer: res.body), Self.svg)
        }
    }

    /// A favicon is served at both favicon addresses, with its real type.
    func testAnUploadedFaviconIsServedAtBothAddresses() async throws {
        let cookies = try await OrgTestSupport.signInAsAdmin(app)
        let png = Self.png(width: 32, height: 32)
        try await upload(png, to: "favicon", cookies: cookies, expect: .noContent)

        for path in ["favicon.ico", "favicon.svg"] {
            try await app.test(.GET, path) { res async in
                XCTAssertEqual(res.headers.first(name: .contentType), "image/png", path)
                XCTAssertEqual(Data(buffer: res.body), png, path)
            }
        }
    }

    func testRemovingAnUploadGoesBackToTheBuiltInImage() async throws {
        let cookies = try await OrgTestSupport.signInAsAdmin(app)
        try await upload(Self.png(width: 180, height: 180), to: "touch_icon", cookies: cookies, expect: .noContent)
        try await app.test(.DELETE, "admin/org/artwork/touch_icon", beforeRequest: { req async in
            req.headers.cookie = cookies
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .noContent)
        })

        let defaultIcon = app.defaultArtwork.touchIconPNG
        try await app.test(.GET, "apple-touch-icon.png") { res async in
            XCTAssertEqual(Data(buffer: res.body), defaultIcon)
        }
    }

    /// An uploaded SVG opened directly runs in a sandbox with no script and no loads.
    func testAnUploadedSVGIsServedWithTheSandboxingHeaders() async throws {
        let cookies = try await OrgTestSupport.signInAsAdmin(app)
        try await upload(Self.svg, to: "favicon", cookies: cookies, expect: .noContent)

        try await app.test(.GET, "favicon.svg") { res async in
            let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
            XCTAssertTrue(csp.contains("default-src 'none'"), csp)
            XCTAssertTrue(csp.contains("sandbox"), csp)
            XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
        }
    }

    func testAnUnchangedImageIsNotSentAgain() async throws {
        var etag = ""
        try await app.test(.GET, "img/logo") { res async in
            etag = res.headers.first(name: .eTag) ?? ""
        }
        XCTAssertFalse(etag.isEmpty)
        try await app.test(.GET, "img/logo", beforeRequest: { req async in
            req.headers.replaceOrAdd(name: .ifNoneMatch, value: etag)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .notModified)
        })
    }

    func testTheWrongTypeForTheSlotIsRefused() async throws {
        let cookies = try await OrgTestSupport.signInAsAdmin(app)
        // The touch icon must be PNG; the logo cannot be ICO.
        let reason = try await upload(Self.svg, to: "touch_icon", cookies: cookies, expect: .unprocessableEntity)
        XCTAssertTrue(reason.contains("PNG"), reason)
        _ = try await upload(Self.ico, to: "logo", cookies: cookies, expect: .unprocessableEntity)
        _ = try await upload(Data("GIF89a not an image TNG takes".utf8), to: "favicon",
                             cookies: cookies, expect: .unprocessableEntity)
        let stored = try await OrgAsset.query(on: app.db).count()
        XCTAssertEqual(stored, 0)
    }

    /// The type is read from the content, never from what the browser says it is.
    func testTheClaimedContentTypeIsIgnored() async throws {
        let cookies = try await OrgTestSupport.signInAsAdmin(app)
        try await app.test(.PUT, "admin/org/artwork/touch_icon", beforeRequest: { req async in
            req.headers.cookie = cookies
            req.headers.contentType = .png
            req.body = ByteBuffer(data: Self.svg)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .unprocessableEntity)
        })
    }

    func testATouchIconOfTheWrongSizeIsRefused() async throws {
        let cookies = try await OrgTestSupport.signInAsAdmin(app)
        let reason = try await upload(Self.png(width: 512, height: 512), to: "touch_icon",
                                      cookies: cookies, expect: .unprocessableEntity)
        XCTAssertTrue(reason.contains("512×512"), reason)
    }

    func testAnUploadOverTheLimitIsRefused() async throws {
        let cookies = try await OrgTestSupport.signInAsAdmin(app)
        var big = Self.png(width: 64, height: 64)
        big.append(Data(count: OrgArtwork.maxBytes))
        let reason = try await upload(big, to: "logo", cookies: cookies, expect: .unprocessableEntity)
        XCTAssertTrue(reason.contains("1 MB"), reason)
        let stored = try await OrgAsset.query(on: app.db).count()
        XCTAssertEqual(stored, 0)
    }

    func testAnUnsafeSVGIsRefusedWithTheReason() async throws {
        let cookies = try await OrgTestSupport.signInAsAdmin(app)
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#.utf8)
        let reason = try await upload(svg, to: "logo", cookies: cookies, expect: .unprocessableEntity)
        XCTAssertTrue(reason.contains("<script>"), reason)
    }

    func testUploadsAreForAdminsOnly() async throws {
        try await app.test(.PUT, "admin/org/artwork/logo", beforeRequest: { req async in
            req.body = ByteBuffer(data: Self.svg)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, .seeOther)
        })
        let stored = try await OrgAsset.query(on: app.db).count()
        XCTAssertEqual(stored, 0)
    }

    func testAnUnknownSlotIsNotFound() async throws {
        let cookies = try await OrgTestSupport.signInAsAdmin(app)
        _ = try await upload(Self.svg, to: "banner", cookies: cookies, expect: .notFound)
    }

    // MARK: - Recognising formats

    func testFormatsAreRecognisedByContent() {
        XCTAssertEqual(OrgArtwork.detect(Self.png(width: 1, height: 1)), .png)
        XCTAssertEqual(OrgArtwork.detect(Self.ico), .ico)
        XCTAssertEqual(OrgArtwork.detect(Self.svg), .svg)
        XCTAssertNil(OrgArtwork.detect(Data("plain text".utf8)))
        XCTAssertEqual(OrgArtwork.pngSize(Self.png(width: 180, height: 120))?.width, 180)
        XCTAssertEqual(OrgArtwork.pngSize(Self.png(width: 180, height: 120))?.height, 120)
    }

    // MARK: - Helpers

    @discardableResult
    private func upload(
        _ data: Data, to slot: String, cookies: HTTPCookies, expect status: HTTPStatus,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> String {
        var reason = ""
        try await app.test(.PUT, "admin/org/artwork/\(slot)", beforeRequest: { req async in
            req.headers.cookie = cookies
            req.headers.contentType = .binary
            req.body = ByteBuffer(data: data)
        }, afterResponse: { res async in
            XCTAssertEqual(res.status, status, res.body.string, file: file, line: line)
            reason = res.body.string
        })
        return reason
    }
}
