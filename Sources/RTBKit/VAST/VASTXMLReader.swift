import Foundation

/// One element of a parsed VAST document, with namespace prefixes removed.
///
/// VAST documents are small, so a plain element tree is the simplest correct model. Mapping it to `VASTDocument` is a
/// separate, pure step (`VASTDecoder`).
struct VASTXMLElement: Sendable, Hashable {
    /// Local name (`vast:Ad` → `Ad`).
    var name: String
    /// Attributes by local name; `xmlns` declarations are dropped.
    var attributes: [String: String]
    /// The element's own character data and CDATA sections, concatenated in document order (untrimmed).
    var text: String
    var children: [VASTXMLElement]
    /// 1-based line of the start tag.
    var line: Int

    init(name: String, attributes: [String: String] = [:], text: String = "", children: [VASTXMLElement] = [], line: Int = 0) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
        self.line = line
    }

    /// Text with surrounding whitespace and newlines removed (URLs, durations, names).
    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func children(named name: String) -> [VASTXMLElement] {
        children.filter { $0.name == name }
    }

    func firstChild(named name: String) -> VASTXMLElement? {
        children.first { $0.name == name }
    }

    /// The attribute `name`, matched exactly first and then case-insensitively (`AdID` vs `adId`).
    func attribute(_ name: String) -> String? {
        if let value = attributes[name] { return value }
        let lowered = name.lowercased()
        return attributes.first { $0.key.lowercased() == lowered }?.value
    }
}

/// Reads XML into a `VASTXMLElement` tree, defensively.
///
/// - The input size, element depth, element count and text volume are capped.
/// - A DTD (`<!DOCTYPE …>`) is rejected before parsing, because VAST never needs one. This rules out entity-expansion
///   attacks such as "billion laughs". External entities are never resolved, and any entity declaration that reaches
///   the parser aborts it.
/// - Namespace prefixes are stripped, so `vast:VAST` and a default `xmlns` are both accepted.
/// - Leading whitespace, a byte-order mark and the XML declaration are removed. The text is already decoded, so a
///   declared `encoding` must not apply to it again.
enum VASTXMLReader {
    struct Limits: Sendable, Hashable {
        var maxBytes: Int
        var maxDepth: Int
        var maxElements: Int
        /// Total character data (all text and CDATA), in UTF-16 code units.
        var maxTextLength: Int

        static let standard = Limits(maxBytes: 4 * 1024 * 1024, maxDepth: 64, maxElements: 50_000, maxTextLength: 8 * 1024 * 1024)
    }

    enum Failure: Error, Sendable, Hashable {
        case empty
        case tooLarge(bytes: Int, limit: Int)
        case doctypeNotAllowed
        case tooDeep(limit: Int)
        case tooManyElements(limit: Int)
        case tooMuchText(limit: Int)
        case entityDeclarationNotAllowed
        case malformed(line: Int, column: Int, message: String)

        var message: String {
            switch self {
            case .empty:
                "The VAST document is empty."
            case let .tooLarge(bytes, limit):
                "The VAST document is \(bytes) bytes; the limit is \(limit)."
            case .doctypeNotAllowed:
                "The document declares a DTD (<!DOCTYPE …>). VAST never uses one, and DTDs are rejected to prevent entity-expansion attacks."
            case let .tooDeep(limit):
                "Elements are nested more than \(limit) levels deep."
            case let .tooManyElements(limit):
                "The document has more than \(limit) elements."
            case let .tooMuchText(limit):
                "The document has more than \(limit) characters of text."
            case .entityDeclarationNotAllowed:
                "The document declares an XML entity, which is not allowed."
            case let .malformed(line, column, message):
                "XML is not well-formed (line \(line), column \(column)): \(message)"
            }
        }
    }

    static func read(_ xml: String, limits: Limits = .standard) -> Result<VASTXMLElement, Failure> {
        let byteCount = xml.utf8.count
        guard byteCount <= limits.maxBytes else { return .failure(.tooLarge(bytes: byteCount, limit: limits.maxBytes)) }

        let body: Substring
        switch strippedProlog(xml) {
        case let .success(stripped): body = stripped
        case let .failure(failure): return .failure(failure)
        }
        guard !body.isEmpty else { return .failure(.empty) }

        let builder = TreeBuilder(limits: limits)
        let parser = XMLParser(data: Data(body.utf8))
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let succeeded = parser.parse()

        if let failure = builder.failure { return .failure(failure) }
        guard succeeded, let root = builder.root else {
            let message = parser.parserError.map { ($0 as NSError).localizedDescription } ?? "unknown parser error"
            return .failure(.malformed(line: parser.lineNumber, column: parser.columnNumber, message: message))
        }
        return .success(root)
    }

    /// Removes a byte-order mark, leading whitespace, the XML declaration and leading comments and processing
    /// instructions, and rejects a DTD. Only the prolog is scanned, so `<!DOCTYPE html>` inside a CDATA section of an
    /// `HTMLResource` is unaffected.
    static func strippedProlog(_ xml: String) -> Result<Substring, Failure> {
        var rest = Substring(xml)
        while true {
            rest = rest.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
            if rest.hasPrefix("<?") {
                guard let end = rest.range(of: "?>") else { return .success(rest) }
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("<!--") {
                guard let end = rest.range(of: "-->") else { return .success(rest) }
                rest = rest[end.upperBound...]
            } else if rest.prefix(9).caseInsensitiveCompare("<!DOCTYPE") == .orderedSame {
                return .failure(.doctypeNotAllowed)
            } else {
                return .success(rest)
            }
        }
    }
}

/// Builds the element tree from `XMLParser` callbacks. Used by one parse on one thread only.
private final class TreeBuilder: NSObject, XMLParserDelegate {
    private let limits: VASTXMLReader.Limits
    private var stack: [VASTXMLElement] = []
    private var elementCount = 0
    private var textLength = 0
    private(set) var root: VASTXMLElement?
    private(set) var failure: VASTXMLReader.Failure?

    init(limits: VASTXMLReader.Limits) {
        self.limits = limits
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard failure == nil else { return }
        elementCount += 1
        guard elementCount <= limits.maxElements else { return abort(parser, .tooManyElements(limit: limits.maxElements)) }
        guard stack.count < limits.maxDepth else { return abort(parser, .tooDeep(limit: limits.maxDepth)) }
        stack.append(VASTXMLElement(name: Self.localName(elementName), attributes: Self.localAttributes(attributeDict),
                                    line: parser.lineNumber))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard failure == nil, let finished = stack.popLast() else { return }
        if stack.isEmpty {
            if root == nil { root = finished }
        } else {
            stack[stack.count - 1].children.append(finished)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        appendText(String(decoding: CDATABlock, as: UTF8.self), parser: parser)
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        abort(parser, .entityDeclarationNotAllowed)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        abort(parser, .entityDeclarationNotAllowed)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        nil
    }

    private func appendText(_ string: String, parser: XMLParser) {
        guard failure == nil, !stack.isEmpty else { return }
        textLength += string.utf16.count
        guard textLength <= limits.maxTextLength else { return abort(parser, .tooMuchText(limit: limits.maxTextLength)) }
        stack[stack.count - 1].text.append(string)
    }

    private func abort(_ parser: XMLParser, _ reason: VASTXMLReader.Failure) {
        if failure == nil { failure = reason }
        parser.abortParsing()
    }

    private static func localName(_ qualifiedName: String) -> String {
        guard let colon = qualifiedName.lastIndex(of: ":") else { return qualifiedName }
        return String(qualifiedName[qualifiedName.index(after: colon)...])
    }

    /// Drops `xmlns` declarations and strips prefixes; an unprefixed attribute wins over a prefixed one of the same name.
    private static func localAttributes(_ attributes: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in attributes.sorted(by: { $0.key < $1.key }) {
            if name == "xmlns" || name.hasPrefix("xmlns:") { continue }
            let local = localName(name)
            if local == name || result[local] == nil {
                result[local] = value
            }
        }
        return result
    }
}
