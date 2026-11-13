import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - SVGValidator

/// Decides whether an uploaded SVG is passive drawing, and refuses it with a reason if not
/// (#89).
///
/// An SVG can carry script, and uploaded artwork is served from TNG's own origin. TNG only
/// shows artwork through `<img>` and `<link rel="icon">`, where browsers run no script, and
/// the artwork routes add a sandboxing CSP for anyone who opens a file directly; this check
/// is the layer in front of those. It rejects rather than rewrites: an admin is present at
/// upload time to fix the file, and what is stored is exactly what was uploaded.
///
/// A file is refused when:
/// - it has a `DOCTYPE` or an entity declaration, ruling out entity expansion and external
///   entities before parsing starts;
/// - it has a processing instruction (`<?xml-stylesheet …?>` would load a stylesheet);
/// - its root is not `<svg>`, or it is not well-formed XML;
/// - it has an element outside ``allowedElements``, or outside the SVG namespace (which
///   covers `<script>` and `<foreignObject>`, named specifically in the reason);
/// - an element has an `on…` attribute;
/// - an `href` or `xlink:href` is anything but a fragment of the same document (`#id`).
enum SVGValidator {

    static let svgNamespace = "http://www.w3.org/2000/svg"

    /// Passive drawing elements: what logos exported from Illustrator and Inkscape use, and
    /// none of them active content.
    static let allowedElements: Set<String> = [
        "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "title", "desc", "defs",
        "linearGradient", "radialGradient", "stop",
        "clipPath", "mask", "pattern", "symbol", "use",
    ]

    /// Why an SVG was refused, in words that tell an admin what to fix.
    struct Rejection: Error, Equatable, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// Checks `data` and throws a ``Rejection`` naming the first thing that disqualifies it.
    static func validate(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Rejection(reason: "The SVG is not UTF-8 text.")
        }
        // Before the parser sees it: a DOCTYPE is where entities are declared, and nothing
        // a logo needs lives there. Matched anywhere, even inside a comment — a false
        // refusal costs an admin one edit, a missed one could cost much more.
        let lowered = text.lowercased()
        if lowered.contains("<!doctype") {
            throw Rejection(reason: "The SVG has a DOCTYPE. Remove it; TNG accepts no DOCTYPE or entity declarations.")
        }
        if lowered.contains("<!entity") {
            throw Rejection(reason: "The SVG declares an entity (<!ENTITY>). Remove it.")
        }

        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let checker = Checker()
        parser.delegate = checker
        let parsed = parser.parse()

        if let rejection = checker.rejection {
            throw rejection
        }
        // swift-corelibs-foundation's parser can report success for a document libxml2
        // complained about, so its error, and the delegate's, count as well.
        let parseError = checker.parseError ?? parser.parserError
        guard parsed, parseError == nil else {
            let detail = parseError.map { " (\($0.localizedDescription))" } ?? ""
            throw Rejection(reason: "The file is not well-formed XML\(detail).")
        }
        guard checker.sawRoot else {
            throw Rejection(reason: "The file has no <svg> element.")
        }
    }

    // MARK: - The parser delegate

    private final class Checker: NSObject, XMLParserDelegate {
        var rejection: Rejection?
        var sawRoot = false
        var parseError: (any Error)?

        private func reject(_ parser: XMLParser, _ reason: String) {
            guard rejection == nil else { return }
            rejection = Rejection(reason: reason)
            parser.abortParsing()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let shown = qName ?? elementName
            if !sawRoot {
                sawRoot = true
                guard elementName == "svg" else {
                    return reject(parser, "The root element is <\(shown)>, not <svg>.")
                }
            }

            switch elementName.lowercased() {
            case "script":
                return reject(parser, "The SVG contains a <script> element. TNG accepts no script in artwork.")
            case "foreignobject":
                return reject(parser, "The SVG contains a <foreignObject> element, which can embed HTML. Remove it.")
            case "style":
                // Illustrator's default export puts colours in a <style> element; one
                // setting puts them on the elements instead, which is accepted.
                return reject(parser, """
                    The SVG has a <style> element. In Illustrator, export with File → Export → \
                    Export As… → SVG, and set Styling to Presentation Attributes.
                    """)
            default:
                break
            }
            guard namespaceURI == SVGValidator.svgNamespace else {
                return reject(parser, """
                    The SVG contains <\(shown)>, which is not an SVG element. Editor metadata \
                    such as Inkscape's is not accepted; save as plain SVG.
                    """)
            }
            guard SVGValidator.allowedElements.contains(elementName) else {
                return reject(parser, """
                    The SVG contains <\(shown)>, which TNG does not accept in artwork. \
                    Accepted elements: \(SVGValidator.allowedElements.sorted().joined(separator: ", ")).
                    """)
            }

            for (attribute, value) in attributeDict {
                let local = attribute.split(separator: ":").last.map(String.init) ?? attribute
                if local.lowercased().hasPrefix("on") {
                    return reject(parser, "<\(shown)> has an event-handler attribute, \(attribute). Remove it.")
                }
                if local.lowercased() == "href" {
                    let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard target.hasPrefix("#"), target.count > 1 else {
                        return reject(parser, """
                            <\(shown)> has \(attribute)="\(value)". Links may only point inside \
                            the same file (#id).
                            """)
                    }
                }
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            if self.parseError == nil { self.parseError = parseError }
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            reject(parser, "The SVG has a processing instruction (<?\(target) …?>). Remove it.")
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            reject(parser, "The SVG declares an entity, \(name). Remove it.")
        }

        func parser(
            _ parser: XMLParser,
            foundExternalEntityDeclarationWithName name: String,
            publicID: String?,
            systemID: String?
        ) {
            reject(parser, "The SVG declares an external entity, \(name). Remove it.")
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            reject(parser, "The SVG refers to an external entity, \(name). Remove it.")
            return nil
        }
    }
}
