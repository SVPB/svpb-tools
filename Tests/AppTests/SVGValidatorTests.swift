import Foundation
import XCTest
@testable import App

/// An uploaded SVG is accepted only when it is passive drawing, and refused with a reason
/// that names what to remove (#89).
final class SVGValidatorTests: XCTestCase {

    private func svg(_ body: String, attributes: String = "") -> Data {
        Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
            viewBox="0 0 100 100"\(attributes)>\(body)</svg>
            """.utf8)
    }

    private func reason(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            try SVGValidator.validate(data)
            XCTFail("Expected a refusal", file: file, line: line)
            return ""
        } catch let rejection as SVGValidator.Rejection {
            return rejection.reason
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: - Accepted

    /// SVPB's own artwork must upload as it stands.
    func testTheSVPBThistleFilesAreAccepted() throws {
        let brand = OrgTestSupport.repositoryRoot.appendingPathComponent("Brand", isDirectory: true)
        let files = ["svpb-thistle.svg", "svpb-thistle-white.svg", "svpb-thistle-square-white.svg",
                     "web/favicon.svg", "web/thistle.svg"]
        for name in files {
            let data = try Data(contentsOf: brand.appendingPathComponent(name))
            XCTAssertNoThrow(try SVGValidator.validate(data), name)
            XCTAssertEqual(OrgArtwork.detect(data), .svg, name)
        }
    }

    func testGradientsClippingMasksAndLocalUseAreAccepted() {
        let data = svg("""
            <title>Logo</title><desc>A test logo</desc>
            <defs>
              <linearGradient id="lg" x1="0" x2="1"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></linearGradient>
              <radialGradient id="rg"><stop offset="0" stop-color="red"/></radialGradient>
              <clipPath id="clip"><circle cx="50" cy="50" r="40"/></clipPath>
              <mask id="m"><rect width="100" height="100" fill="white"/></mask>
              <pattern id="p" width="4" height="4"><line x1="0" y1="0" x2="4" y2="4" stroke="black"/></pattern>
              <symbol id="mark"><polygon points="0,0 10,0 5,8"/><polyline points="0,0 5,5"/></symbol>
            </defs>
            <g clip-path="url(#clip)" mask="url(#m)" style="opacity:.9" class="cls-1">
              <path d="M0 0L100 100" fill="url(#lg)"/>
              <ellipse cx="50" cy="50" rx="10" ry="5" fill="url(#rg)"/>
              <rect width="10" height="10" fill="url(#p)"/>
              <text x="10" y="90">Band <tspan font-weight="bold">Name</tspan></text>
            </g>
            <use href="#mark" x="20"/>
            <use xlink:href="#mark" x="40"/>
            """)
        XCTAssertNoThrow(try SVGValidator.validate(data))
    }

    // MARK: - Refused

    func testADoctypeIsRefused() {
        let data = Data("""
            <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
            <svg xmlns="http://www.w3.org/2000/svg"/>
            """.utf8)
        XCTAssertTrue(reason(data).contains("DOCTYPE"))
    }

    /// The "billion laughs": refused before the parser can expand anything.
    func testAnEntityExpansionIsRefused() {
        let data = Data("""
            <?xml version="1.0"?>
            <!DOCTYPE lolz [
              <!ENTITY lol "lol">
              <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
              <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
            ]>
            <svg xmlns="http://www.w3.org/2000/svg"><text>&lol3;</text></svg>
            """.utf8)
        XCTAssertTrue(reason(data).contains("DOCTYPE"))
    }

    func testAnExternalEntityIsRefused() {
        let data = Data("""
            <!doctype svg [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
            <svg xmlns="http://www.w3.org/2000/svg"><text>&xxe;</text></svg>
            """.utf8)
        XCTAssertTrue(reason(data).contains("DOCTYPE"))
    }

    func testScriptIsRefused() {
        XCTAssertTrue(reason(svg("<script>alert(document.cookie)</script>")).contains("<script>"))
    }

    func testForeignObjectIsRefused() {
        let data = svg(#"<foreignObject><div xmlns="http://www.w3.org/1999/xhtml">hi</div></foreignObject>"#)
        XCTAssertTrue(reason(data).contains("<foreignObject>"))
    }

    func testAnEventHandlerIsRefused() {
        XCTAssertTrue(reason(svg("<rect/>", attributes: #" onload="alert(1)""#)).contains("onload"))
        XCTAssertTrue(reason(svg(#"<rect onClick="alert(1)"/>"#)).contains("onClick"))
    }

    func testAnExternalHrefIsRefused() {
        let message = reason(svg(#"<use href="https://example.com/sprite.svg#a"/>"#))
        XCTAssertTrue(message.contains("https://example.com/sprite.svg#a"), message)
        XCTAssertTrue(reason(svg(#"<use xlink:href="other.svg#a"/>"#)).contains("xlink:href"))
    }

    func testAJavascriptHrefIsRefused() {
        let message = reason(svg(#"<use xlink:href="javascript:alert(1)"/>"#))
        XCTAssertTrue(message.contains("javascript:alert(1)"), message)
    }

    func testAnElementOutsideTheAllowlistIsRefused() {
        for element in ["image", "a", "animate", "set", "iframe"] {
            let message = reason(svg("<\(element)/>"))
            XCTAssertTrue(message.contains("<\(element)>"), "\(element): \(message)")
        }
    }

    /// Illustrator's default export; the message says which setting avoids it.
    func testAStyleElementIsRefusedWithTheIllustratorSetting() {
        let message = reason(svg("<defs><style>.cls-1{fill:#aa04bc;}</style></defs><rect class=\"cls-1\"/>"))
        XCTAssertTrue(message.contains("<style>"), message)
        XCTAssertTrue(message.contains("Presentation Attributes"), message)
    }

    /// Inkscape's own elements are not SVG; the message says to save as plain SVG.
    func testEditorMetadataIsRefusedByName() {
        let data = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" \
            xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd">\
            <sodipodi:namedview id="nv"/><rect/></svg>
            """.utf8)
        let message = reason(data)
        XCTAssertTrue(message.contains("sodipodi:namedview"), message)
        XCTAssertTrue(message.contains("plain SVG"), message)
    }

    func testAStylesheetInstructionIsRefused() {
        let data = Data("""
            <?xml-stylesheet href="https://example.com/x.css"?>
            <svg xmlns="http://www.w3.org/2000/svg"/>
            """.utf8)
        XCTAssertTrue(reason(data).contains("xml-stylesheet"))
    }

    func testARootOtherThanSVGIsRefused() {
        XCTAssertTrue(reason(Data(#"<html><svg xmlns="http://www.w3.org/2000/svg"/></html>"#.utf8)).contains("<html>"))
    }

    func testMalformedXMLIsRefused() {
        XCTAssertTrue(reason(Data(#"<svg xmlns="http://www.w3.org/2000/svg"><rect></svg>"#.utf8)).contains("well-formed"))
    }

    func testSVGWithoutTheNamespaceIsRefused() {
        XCTAssertTrue(reason(Data("<svg><rect/></svg>".utf8)).contains("not an SVG element"))
    }
}
