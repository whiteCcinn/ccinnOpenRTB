import Foundation

/// Pretty-prints XML (VAST) and HTML by changing only the whitespace between tags (pure, linear, byte-level). Tags and
/// their attributes, character data, CDATA, comments and raw text (`script`, `style` …) are copied as typed.
///
/// - XML: an element with child elements gets one child per line; an element holding only text, CDATA or comments is
///   copied as typed, and so is one mixing text with elements, so every value a VAST reader trims reads the same.
///   Nesting is strict.
/// - HTML: a line break goes only where the browser discards whitespace with the default styles — next to a
///   block-level element or `<br>`, inside `<head>`, before the first content of a line — so the creative renders as
///   before. Inline runs (`<a><img><img></a>`) stay on one line; `pre` and raw text are copied as typed; an element
///   styled `display: inline…` is inline. Nesting is lenient, with the common implied end tags (`li`, `p`, cells).
enum TagFormatter {
    enum Dialect: Sendable {
        case xml, html
    }

    enum Failure: Error, Equatable, Sendable {
        case empty
        /// A tag, comment, CDATA section or raw-text element (`script` …) without its end.
        case unterminated(line: Int)
        /// XML: `close` ends `open`.
        case mismatched(open: String, close: String, line: Int)
        /// XML: an end tag with no element open.
        case unexpectedClose(String, line: Int)
        /// XML: still open at the end (the line of its start tag).
        case unclosed(String, line: Int)
    }

    static func prettyPrinted(_ text: String, dialect: Dialect, indentWidth: Int = 2) -> Result<String, Failure> {
        let bytes = Array(text.utf8)
        let tokens: [Token]
        switch Tokenizer(bytes: bytes, dialect: dialect).tokens() {
        case let .success(found): tokens = found
        case let .failure(failure): return .failure(failure)
        }
        guard tokens.contains(where: { $0.kind != .text || !Self.isBlank(bytes[$0.range]) }) else { return .failure(.empty) }
        var printer = Printer(bytes: bytes, indentWidth: indentWidth)
        switch dialect {
        case .xml:
            if let failure = printer.printXML(tokens) { return .failure(failure) }
        case .html:
            printer.printHTML(tokens)
        }
        return .success(String(decoding: printer.output, as: UTF8.self))
    }

    // MARK: Tokens

    struct Token {
        enum Kind: Equatable {
            case text, startTag, endTag, comment, cdata, declaration
            /// HTML `script`, `style`, `textarea` …: the start tag, the raw text and the end tag, as one token.
            case rawElement
        }

        var kind: Kind
        var range: Range<Int>
        /// Tags and raw elements: the name, lower-cased in HTML.
        var name = ""
        var selfClosing = false
    }

    /// One pass over the bytes. A `<` that starts no tag, comment or declaration is text.
    private struct Tokenizer {
        let bytes: [UInt8]
        let dialect: Dialect

        func tokens() -> Result<[Token], Failure> {
            var tokens: [Token] = []
            var index = 0
            var textStart = 0
            let count = bytes.count
            func flushText(upTo end: Int) {
                if textStart < end { tokens.append(Token(kind: .text, range: textStart..<end)) }
            }
            while index < count {
                guard bytes[index] == .lessThan, index + 1 < count else {
                    index += 1
                    continue
                }
                let next = bytes[index + 1]
                let token: Token
                if hasPrefix("<!--", at: index) {
                    guard let close = find("-->", from: index + 4) else { return .failure(.unterminated(line: line(at: index))) }
                    token = Token(kind: .comment, range: index..<(close + 3))
                } else if hasPrefix("<![CDATA[", at: index) {
                    guard let close = find("]]>", from: index + 9) else { return .failure(.unterminated(line: line(at: index))) }
                    token = Token(kind: .cdata, range: index..<(close + 3))
                } else if next == .bang || next == .question {
                    let terminator = next == .question && dialect == .xml ? "?>" : ">"
                    guard let close = find(terminator, from: index + 2) else { return .failure(.unterminated(line: line(at: index))) }
                    token = Token(kind: .declaration, range: index..<(close + terminator.utf8.count))
                } else if next == .slash, index + 2 < count, isNameStart(bytes[index + 2]) {
                    guard let close = find(">", from: index + 2) else { return .failure(.unterminated(line: line(at: index))) }
                    token = Token(kind: .endTag, range: index..<(close + 1), name: name(at: index + 2))
                } else if isNameStart(next) {
                    switch startTag(at: index) {
                    case let .success(tag): token = tag
                    case let .failure(failure): return .failure(failure)
                    }
                } else {
                    index += 1
                    continue
                }
                flushText(upTo: index)
                tokens.append(token)
                index = token.range.upperBound
                textStart = index
            }
            flushText(upTo: count)
            return .success(tokens)
        }

        /// A start tag; a quote opens a value only after `=`, as in HTML. In HTML a raw-text element runs to its end tag.
        private func startTag(at start: Int) -> Result<Token, Failure> {
            var index = start + 1
            let count = bytes.count
            while index < count, bytes[index] != .greaterThan {
                if bytes[index] == .equals {
                    var value = index + 1
                    while value < count, isSpace(bytes[value]) { value += 1 }
                    if value < count, bytes[value] == .quote || bytes[value] == .apostrophe {
                        guard let close = bytes[(value + 1)...].firstIndex(of: bytes[value]) else {
                            return .failure(.unterminated(line: line(at: start)))
                        }
                        index = close + 1
                        continue
                    }
                }
                index += 1
            }
            guard index < count else { return .failure(.unterminated(line: line(at: start))) }
            let name = name(at: start + 1)
            var token = Token(kind: .startTag, range: start..<(index + 1), name: name, selfClosing: bytes[index - 1] == .slash)
            if dialect == .html, !token.selfClosing, HTML.rawText.contains(name) {
                guard let close = find("</" + name, from: index + 1, caseInsensitive: true),
                      let end = find(">", from: close + 2) else { return .failure(.unterminated(line: line(at: start))) }
                token.kind = .rawElement
                token.range = start..<(end + 1)
            }
            return .success(token)
        }

        private func name(at start: Int) -> String {
            var end = start
            while end < bytes.count, isNameByte(bytes[end]) { end += 1 }
            let name = String(decoding: bytes[start..<end], as: UTF8.self)
            return dialect == .html ? name.lowercased() : name
        }

        private func hasPrefix(_ prefix: String, at index: Int) -> Bool {
            let pattern = Array(prefix.utf8)
            return index + pattern.count <= bytes.count && bytes[index..<(index + pattern.count)].elementsEqual(pattern)
        }

        private func find(_ needle: String, from start: Int, caseInsensitive: Bool = false) -> Int? {
            let pattern = Array(needle.utf8)
            guard let first = pattern.first else { return nil }
            var index = start
            let last = bytes.count - pattern.count
            while index <= last {
                if let found = bytes[index...last].firstIndex(where: { fold($0, caseInsensitive) == first }) {
                    var offset = 1
                    while offset < pattern.count, fold(bytes[found + offset], caseInsensitive) == pattern[offset] { offset += 1 }
                    if offset == pattern.count { return found }
                    index = found + 1
                } else {
                    return nil
                }
            }
            return nil
        }

        private func fold(_ byte: UInt8, _ caseInsensitive: Bool) -> UInt8 {
            caseInsensitive && byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
        }

        private func line(at index: Int) -> Int {
            bytes[..<min(index, bytes.count)].reduce(1) { $1 == .newline ? $0 + 1 : $0 }
        }

        private func isNameStart(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ":")
        }

        private func isNameByte(_ byte: UInt8) -> Bool {
            isNameStart(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
        }
    }

    // MARK: Printing

    private struct Printer {
        let bytes: [UInt8]
        let indentWidth: Int
        var output: [UInt8] = []

        init(bytes: [UInt8], indentWidth: Int) {
            self.bytes = bytes
            self.indentWidth = indentWidth
            output.reserveCapacity(bytes.count + bytes.count / 4)
        }

        private mutating func newline(depth: Int) {
            guard !output.isEmpty else { return }
            output.append(.newline)
            output.append(contentsOf: repeatElement(UInt8.space, count: depth * indentWidth))
        }

        private mutating func emit(_ range: Range<Int>) {
            output.append(contentsOf: bytes[range])
        }

        // MARK: XML

        /// One child per line in elements that hold only elements (and comments); everything else as typed.
        mutating func printXML(_ tokens: [Token]) -> Failure? {
            // Pass 1: match the tags and note which elements hold elements, and which hold text or CDATA.
            var matching = [Int](repeating: -1, count: tokens.count)
            var holdsElements = [Bool](repeating: false, count: tokens.count)
            var holdsText = [Bool](repeating: false, count: tokens.count)
            var open: [Int] = []
            for (index, token) in tokens.enumerated() {
                switch token.kind {
                case .startTag:
                    if let parent = open.last { holdsElements[parent] = true }
                    if !token.selfClosing { open.append(index) }
                case .endTag:
                    guard let start = open.popLast() else { return .unexpectedClose(token.name, line: line(at: token.range.lowerBound)) }
                    guard tokens[start].name == token.name else {
                        return .mismatched(open: tokens[start].name, close: token.name, line: line(at: token.range.lowerBound))
                    }
                    matching[start] = index
                case .text, .cdata:
                    if let parent = open.last, token.kind == .cdata || !TagFormatter.isBlank(bytes[token.range]) { holdsText[parent] = true }
                case .comment, .declaration, .rawElement:
                    break
                }
            }
            if let start = open.last { return .unclosed(tokens[start].name, line: line(at: tokens[start].range.lowerBound)) }

            // Pass 2: print.
            var depth = 0
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                switch token.kind {
                case .text:
                    let trimmed = TagFormatter.trimmed(token.range, in: bytes)
                    if !trimmed.isEmpty {
                        newline(depth: depth)
                        emit(trimmed)
                    }
                case .startTag where !token.selfClosing && (!holdsElements[index] || holdsText[index]):
                    newline(depth: depth)
                    let end = matching[index]
                    emit(token.range.lowerBound..<tokens[end].range.upperBound)
                    index = end
                case .startTag:
                    newline(depth: depth)
                    emit(token.range)
                    if !token.selfClosing { depth += 1 }
                case .endTag:
                    depth -= 1
                    newline(depth: depth)
                    emit(token.range)
                case .comment, .cdata, .declaration, .rawElement:
                    newline(depth: depth)
                    emit(token.range)
                }
                index += 1
            }
            return nil
        }

        private func line(at index: Int) -> Int {
            bytes[..<index].reduce(1) { $1 == .newline ? $0 + 1 : $0 }
        }

        // MARK: HTML

        /// What a token is to the line it is on.
        private enum Role {
            /// Starts or ends a block, or breaks the line (`br`): whitespace next to it is not rendered.
            case blockBoundary
            /// Rendered on the line: text, an inline element, an image.
            case content
            /// Not rendered (a comment, `script`, `meta` …): whitespace next to it is rendered when the line has content.
            case hidden
        }

        mutating func printHTML(_ tokens: [Token]) {
            var stack = OpenElements()
            var pending: [UInt8] = []
            var previous: Role?
            var atLineStart = true

            for token in tokens {
                if token.kind == .text {
                    if stack.isPreformatted {
                        output.append(contentsOf: pending)
                        pending = []
                        emit(token.range)
                        previous = .content
                        atLineStart = false
                        continue
                    }
                    let core = TagFormatter.trimmed(token.range, in: bytes)
                    guard !core.isEmpty else {
                        pending.append(contentsOf: bytes[token.range])
                        continue
                    }
                    pending.append(contentsOf: bytes[token.range.lowerBound..<core.lowerBound])
                    place(role: .content, depth: stack.count, previous: previous, atLineStart: atLineStart, preformatted: false,
                          inHead: stack.isOpen("head"), pending: &pending)
                    emit(core)
                    pending = Array(bytes[core.upperBound..<token.range.upperBound])
                    previous = .content
                    atLineStart = false
                    continue
                }

                let preformatted = stack.isPreformatted
                let role: Role
                var depth = stack.count
                switch token.kind {
                case .startTag, .rawElement:
                    if let implied = TagFormatter.impliedEnd(by: token.name, in: stack.elements) { stack.close(from: implied) }
                    depth = stack.count
                    let isBlock = HTML.block.contains(token.name) && !HTML.isStyledInline(bytes[token.range])
                    role = isBlock || token.name == "br" ? .blockBoundary : HTML.hidden.contains(token.name) ? .hidden : .content
                    if token.kind == .startTag, !token.selfClosing, !HTML.void.contains(token.name) {
                        stack.open(OpenElement(name: token.name, isBlock: isBlock))
                    }
                case .endTag:
                    if let open = stack.lastIndex(of: token.name) {
                        role = stack.elements[open].isBlock ? .blockBoundary : HTML.hidden.contains(token.name) ? .hidden : .content
                        stack.close(from: open)
                    } else {
                        role = .content // a stray end tag: kept where it is
                    }
                    depth = stack.count
                case .declaration:
                    role = .blockBoundary
                case .comment, .cdata, .text:
                    role = .hidden
                }
                let inHead = stack.isOpen("head") || token.name == "head"
                place(role: role, depth: depth, previous: previous, atLineStart: atLineStart, preformatted: preformatted, inHead: inHead,
                      pending: &pending)
                emit(token.range)
                switch role {
                case .blockBoundary: atLineStart = true
                case .content: atLineStart = false
                case .hidden: break
                }
                previous = role
            }
        }

        /// A line break before the token where whitespace is not rendered; otherwise the whitespace that was there.
        private mutating func place(role: Role, depth: Int, previous: Role?, atLineStart: Bool, preformatted: Bool, inHead: Bool,
                                    pending: inout [UInt8]) {
            defer { pending = [] }
            guard !output.isEmpty else { return }
            let canBreak = !preformatted && (inHead || atLineStart || role == .blockBoundary || previous == .blockBoundary)
            if canBreak {
                newline(depth: depth)
            } else {
                output.append(contentsOf: pending)
            }
        }
    }

    // MARK: HTML rules

    enum HTML {
        static let void: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "keygen", "link", "meta", "param",
                                        "source", "track", "wbr"]
        /// Copied as typed up to their end tag.
        static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "noscript"]
        /// Block-level by default (whitespace around them is not rendered), and `br`.
        static let block: Set<String> = [
            "address", "article", "aside", "blockquote", "body", "br", "caption", "center", "col", "colgroup", "dd", "details", "dialog",
            "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frameset", "h1", "h2", "h3", "h4", "h5", "h6",
            "head", "header", "hgroup", "hr", "html", "legend", "li", "listing", "main", "menu", "nav", "ol", "optgroup", "option", "p",
            "pre", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
        ]
        /// Not rendered.
        static let hidden: Set<String> = ["base", "link", "meta", "noscript", "script", "style", "template", "title"]
        /// Start tags that close an open `p`.
        static let closesParagraph: Set<String> = [
            "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset", "figcaption",
            "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "listing", "main", "menu", "nav",
            "ol", "p", "pre", "search", "section", "summary", "table", "ul",
        ]

        /// A `style` attribute with `display: inline…`. Deliberately loose (any tag mentioning both): a false match only
        /// keeps a line together.
        static func isStyledInline(_ tag: ArraySlice<UInt8>) -> Bool {
            let lowered = String(decoding: tag, as: UTF8.self).lowercased()
            return lowered.contains("display") && lowered.contains("inline")
        }
    }

    /// An element open in HTML, and whether it is block-level (as styled).
    fileprivate struct OpenElement {
        var name: String
        var isBlock: Bool
    }

    /// The HTML printer's open elements, with a count per name so that "is a `pre` open?" and "is this end tag's element
    /// open?" never scan the stack: deeply nested markup stays linear.
    fileprivate struct OpenElements {
        private(set) var elements: [OpenElement] = []
        private var counts: [String: Int] = [:]

        var count: Int { elements.count }
        var isPreformatted: Bool { isOpen("pre") || isOpen("listing") }

        func isOpen(_ name: String) -> Bool {
            counts[name, default: 0] > 0
        }

        /// The innermost open element named `name`; the scan stops there, and everything it passes is then closed.
        func lastIndex(of name: String) -> Int? {
            isOpen(name) ? elements.lastIndex { $0.name == name } : nil
        }

        mutating func open(_ element: OpenElement) {
            elements.append(element)
            counts[element.name, default: 0] += 1
        }

        /// Closes the element at `index` and every element inside it.
        mutating func close(from index: Int) {
            for element in elements[index...] { counts[element.name, default: 1] -= 1 }
            elements.removeSubrange(index...)
        }
    }

    /// Where the end tags a start tag implies begin: the open `li` before another `li`, a `p` before a block, cells and
    /// rows. `nil`: none. Only the innermost `impliedEndReach` elements are looked at, so a deep stack of inline elements
    /// costs a bounded scan per tag (it only affects indentation).
    fileprivate static let impliedEndReach = 64

    fileprivate static func impliedEnd(by name: String, in stack: [OpenElement]) -> Int? {
        let closes: Set<String>
        let stopsAt: Set<String>
        switch name {
        case "li": (closes, stopsAt) = (["li"], ["ul", "ol", "menu", "table", "td", "th", "body", "html"])
        case "dt", "dd": (closes, stopsAt) = (["dt", "dd"], ["dl", "table", "td", "th", "body", "html"])
        case "td", "th": (closes, stopsAt) = (["td", "th"], ["tr", "table"])
        case "tr": (closes, stopsAt) = (["tr"], ["table", "thead", "tbody", "tfoot"])
        case "thead", "tbody", "tfoot": (closes, stopsAt) = (["thead", "tbody", "tfoot"], ["table"])
        case "option": (closes, stopsAt) = (["option"], ["select", "datalist", "optgroup"])
        case "optgroup": (closes, stopsAt) = (["optgroup"], ["select"])
        default:
            guard HTML.closesParagraph.contains(name) else { return nil }
            // A block start closes an open `p` unless another block is in between.
            for index in stack.indices.reversed().prefix(impliedEndReach) {
                if stack[index].name == "p" { return index }
                if stack[index].isBlock { return nil }
            }
            return nil
        }
        for index in stack.indices.reversed().prefix(impliedEndReach) {
            let open = stack[index].name
            if closes.contains(open) { return index }
            if stopsAt.contains(open) { return nil }
        }
        return nil
    }

    fileprivate static func isBlank(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.allSatisfy(isSpace)
    }

    /// `range` without its leading and trailing whitespace.
    fileprivate static func trimmed(_ range: Range<Int>, in bytes: [UInt8]) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, isSpace(bytes[lower]) { lower += 1 }
        while upper > lower, isSpace(bytes[upper - 1]) { upper -= 1 }
        return lower..<upper
    }
}

private func isSpace(_ byte: UInt8) -> Bool {
    byte == .space || byte == .newline || byte == 0x09 || byte == 0x0D || byte == 0x0C
}

private extension UInt8 {
    static let lessThan = UInt8(ascii: "<")
    static let greaterThan = UInt8(ascii: ">")
    static let slash = UInt8(ascii: "/")
    static let bang = UInt8(ascii: "!")
    static let question = UInt8(ascii: "?")
    static let equals = UInt8(ascii: "=")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")
    static let space = UInt8(ascii: " ")
    static let newline = UInt8(ascii: "\n")
}
