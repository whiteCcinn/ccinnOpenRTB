import Foundation

/// Text that is the inside of a JSON string literal — markup or JSON copied out of a log or a bid response
/// (`<VAST version=\"3.0\">`, Go's `<VAST …>`) — decoded back (pure, linear in the text).
///
/// It decodes only when the escaping is unambiguous, so real markup is never altered:
/// - every `"` is escaped and every escape is a valid JSON escape (a raw tab or line break is kept, for a wrapped log
///   line), and
/// - the text is wrapped in quotes; or it starts, after whitespace and escaped whitespace, with an escaped `<` or `"`, or
///   with `{` / `[` followed by `\"`; or it is markup with a tag attribute quoted with `\"` outside `script`, `style`,
///   comments and CDATA. (`document.write('<img src=\"x\">')` in a real banner is JavaScript, not escaping.)
public enum JSONEscapedText {
    public struct Unescaped: Equatable, Sendable {
        public var text: String
        /// How many times it was decoded: 2 when it was escaped twice.
        public var levels: Int
    }

    /// `text` decoded while it is still unambiguously escaped, at most `maxLevels` times; `nil` when it is not escaped.
    public static func unescaped(_ text: String, maxLevels: Int = 3) -> Unescaped? {
        var current = Array(text.utf8)
        var levels = 0
        while levels < maxLevels, let decoded = decodeOnce(current) {
            current = decoded
            levels += 1
        }
        guard levels > 0 else { return nil }
        return Unescaped(text: String(decoding: current, as: UTF8.self), levels: levels)
    }

    private static func decodeOnce(_ bytes: [UInt8]) -> [UInt8]? {
        var start = 0
        var end = bytes.count
        while start < end, isSpace(bytes[start]) { start += 1 }
        while end > start, isSpace(bytes[end - 1]) { end -= 1 }
        guard start < end else { return nil }
        if end - start >= 2, bytes[start] == .quote, bytes[end - 1] == .quote, let decoded = decodedBody(bytes[(start + 1)..<(end - 1)]) {
            return decoded
        }
        // Decoding fails at the first raw quote, which real markup and JSON have early; the signal is checked after.
        guard let decoded = decodedBody(bytes[start..<end]), hasEscapingSignal(bytes[start..<end]) else { return nil }
        return decoded
    }

    /// The contents of a JSON string (no surrounding quotes) decoded; `nil` on a raw `"`, a control character other than
    /// tab and line breaks, or an invalid escape.
    private static func decodedBody(_ body: ArraySlice<UInt8>) -> [UInt8]? {
        var output: [UInt8] = []
        var index = body.startIndex
        let end = body.endIndex
        while index < end {
            let byte = body[index]
            if byte == .quote { return nil }
            if byte < 0x20, byte != .tab, byte != .lineFeed, byte != .carriageReturn { return nil }
            guard byte == .backslash else {
                output.append(byte)
                index += 1
                continue
            }
            guard index + 1 < end else { return nil }
            switch body[index + 1] {
            case .quote: output.append(.quote)
            case .backslash: output.append(.backslash)
            case .slash: output.append(.slash)
            case UInt8(ascii: "b"): output.append(0x08)
            case UInt8(ascii: "f"): output.append(0x0C)
            case UInt8(ascii: "n"): output.append(.lineFeed)
            case UInt8(ascii: "r"): output.append(.carriageReturn)
            case UInt8(ascii: "t"): output.append(.tab)
            case UInt8(ascii: "u"):
                guard let unit = hexUnit(body, at: index + 2) else { return nil }
                index += 6
                var scalar: Unicode.Scalar? = Unicode.Scalar(unit)
                if (0xD800...0xDBFF).contains(unit) {
                    // A high surrogate pairs with an escaped low surrogate; alone, it cannot be in a string.
                    if index + 1 < end, body[index] == .backslash, body[index + 1] == UInt8(ascii: "u"),
                       let low = hexUnit(body, at: index + 2), (0xDC00...0xDFFF).contains(low) {
                        scalar = Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00))
                        index += 6
                    }
                }
                UTF8.encode(scalar ?? "\u{FFFD}") { output.append($0) }
                continue
            default:
                return nil
            }
            index += 2
        }
        return output
    }

    private static func hexUnit(_ bytes: ArraySlice<UInt8>, at index: Int) -> UInt16? {
        guard index + 4 <= bytes.endIndex else { return nil }
        var value: UInt16 = 0
        for offset in 0..<4 {
            guard let digit = hexValue(bytes[index + offset]) else { return nil }
            value = value << 4 | UInt16(digit)
        }
        return value
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    // MARK: Signal

    /// Something only an escaped text has: an escaped `<` or `"` first, `{\"` / `[\"`, or an attribute quoted with `\"` (or
    /// with `\\\"`, escaped twice).
    private static func hasEscapingSignal(_ text: ArraySlice<UInt8>) -> Bool {
        let end = text.endIndex
        var index = afterWhitespace(text, from: text.startIndex)
        guard index < end else { return false }
        switch text[index] {
        case .backslash:
            if isEscapedQuote(text, at: index) { return true }
            var after = index
            while after < end, text[after] == .backslash { after += 1 }
            return after < end && text[after] == UInt8(ascii: "u") && hexUnit(text, at: after + 1) == 0x3C
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            // `{\"id\"…`, also pretty-printed: `{\n  \"id\"…`.
            while index < end, text[index] == UInt8(ascii: "{") || text[index] == UInt8(ascii: "[") {
                index = afterWhitespace(text, from: index + 1)
            }
            return isEscapedQuote(text, at: index)
        case UInt8(ascii: "<"):
            return hasAttributeQuotedWithEscapes(text, from: index)
        default:
            return false
        }
    }

    /// A tag outside scripts, styles, comments and CDATA with a value quoted with `\"` (spaces allowed after `=`). Values in
    /// single quotes or unquoted are skipped: `onclick='x=\"…\"'` is JavaScript.
    private static func hasAttributeQuotedWithEscapes(_ text: ArraySlice<UInt8>, from start: Int) -> Bool {
        var index = start
        let end = text.endIndex
        while index < end {
            guard text[index] == UInt8(ascii: "<"), index + 1 < end else {
                index += 1
                continue
            }
            if hasPrefix(text, at: index, "<!--") {
                guard let close = find(text, "-->", from: index + 4) else { return false }
                index = close + 3
                continue
            }
            if hasPrefix(text, at: index, "<![CDATA[") {
                guard let close = find(text, "]]>", from: index + 9) else { return false }
                index = close + 3
                continue
            }
            let next = text[index + 1]
            guard isLetter(next) || next == UInt8(ascii: "?") || next == UInt8(ascii: "!") else {
                index += 1
                continue
            }
            var cursor = index + 1
            while cursor < end, text[cursor] != UInt8(ascii: ">") {
                guard text[cursor] == UInt8(ascii: "=") else {
                    cursor += 1
                    continue
                }
                var value = cursor + 1
                while value < end, isSpace(text[value]) { value += 1 }
                if isEscapedQuote(text, at: value) { return true }
                if value < end, text[value] == UInt8(ascii: "'") {
                    guard let close = text[(value + 1)...].firstIndex(of: UInt8(ascii: "'")) else { return false }
                    cursor = close + 1
                } else {
                    while value < end, !isSpace(text[value]), text[value] != UInt8(ascii: ">") { value += 1 }
                    cursor = value
                }
            }
            guard cursor < end else { return false }
            var nameEnd = index + 1
            while nameEnd < cursor, isLetter(text[nameEnd]) { nameEnd += 1 }
            if let name = ["script", "style"].first(where: { equalsIgnoringCase(text[(index + 1)..<nameEnd], $0) }) {
                // Where a browser ends it; escaped by PHP's `json_encode`, the end tag is `<\/script>`.
                guard let close = HTMLRawText.endTagStart(of: name, in: text, from: cursor + 1)
                    ?? find(text, "<\\/" + name, from: cursor + 1, caseInsensitive: true) else { return false }
                index = close + 2
                continue
            }
            index = cursor + 1
        }
        return false
    }

    /// After whitespace and escaped whitespace (`\n`, `\t`, also escaped twice: `\\n`).
    private static func afterWhitespace(_ text: ArraySlice<UInt8>, from start: Int) -> Int {
        var index = start
        let end = text.endIndex
        while index < end {
            if isSpace(text[index]) {
                index += 1
                continue
            }
            var run = index
            while run < end, text[run] == .backslash { run += 1 }
            guard run > index, run < end, [UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t")].contains(text[run]) else { break }
            index = run + 1
        }
        return index
    }

    /// `\"`, or `\\\"` escaped twice: an odd run of backslashes, then a quote.
    private static func isEscapedQuote(_ text: ArraySlice<UInt8>, at start: Int) -> Bool {
        var index = start
        while index < text.endIndex, text[index] == .backslash { index += 1 }
        let run = index - start
        return run % 2 == 1 && index < text.endIndex && text[index] == .quote
    }

    private static func hasPrefix(_ text: ArraySlice<UInt8>, at index: Int, _ prefix: String) -> Bool {
        let pattern = Array(prefix.utf8)
        guard index + pattern.count <= text.endIndex else { return false }
        return text[index..<(index + pattern.count)].elementsEqual(pattern)
    }

    private static func find(_ text: ArraySlice<UInt8>, _ needle: String, from start: Int, caseInsensitive: Bool = false) -> Int? {
        let pattern = Array(needle.utf8)
        guard let first = pattern.first, start < text.endIndex else { return nil }
        var index = start
        let last = text.endIndex - pattern.count
        while index <= last {
            if lowered(text[index], caseInsensitive) == first {
                var offset = 1
                while offset < pattern.count, lowered(text[index + offset], caseInsensitive) == pattern[offset] { offset += 1 }
                if offset == pattern.count { return index }
            }
            index += 1
        }
        return nil
    }

    private static func equalsIgnoringCase(_ bytes: ArraySlice<UInt8>, _ word: String) -> Bool {
        bytes.count == word.utf8.count && zip(bytes, word.utf8).allSatisfy { lowered($0, true) == $1 }
    }

    private static func lowered(_ byte: UInt8, _ caseInsensitive: Bool) -> UInt8 {
        caseInsensitive && byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == .space || byte == .tab || byte == .lineFeed || byte == .carriageReturn
    }
}

private extension UInt8 {
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let slash = UInt8(ascii: "/")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
}
