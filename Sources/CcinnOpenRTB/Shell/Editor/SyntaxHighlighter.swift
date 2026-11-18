import Foundation

/// Token spans for the editors' JSON / XML highlighting (pure; scans UTF-16 code units once, so the ranges apply to the
/// text view's string directly). Unterminated strings, comments and tags run to the end of the text.
enum SyntaxHighlighter {
    enum Language: Equatable, Sendable {
        case json, xml, plain

        /// JSON for `{` / `[`, XML for `<` (VAST, HTML), plain otherwise (a VAST tag URL).
        static func detect(_ text: String) -> Language {
            for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                switch scalar {
                case "{", "[": return .json
                case "<": return .xml
                default: return .plain
                }
            }
            return .plain
        }
    }

    enum Kind: String, Equatable, Sendable {
        case key, string, number, keyword, tag, attribute, comment, cdata
    }

    struct Span: Equatable, Sendable {
        var range: NSRange
        var kind: Kind
    }

    /// Texts longer than this (UTF-16 units) are highlighted up to here only, keeping a 1 MB paste responsive.
    static let maximumHighlightedLength = 600_000

    static func spans(in text: String, language: Language) -> [Span] {
        let units = Array(text.utf16.prefix(maximumHighlightedLength))
        switch language {
        case .json: return json(units)
        case .xml: return xml(units)
        case .plain: return []
        }
    }

    // MARK: JSON

    private static func json(_ units: [UInt16]) -> [Span] {
        var spans: [Span] = []
        let count = units.count
        var index = 0
        while index < count {
            let unit = units[index]
            if unit == .quote {
                let end = endOfString(units, from: index)
                var next = end
                while next < count, isSpace(units[next]) { next += 1 }
                let isKey = next < count && units[next] == .colon
                spans.append(Span(range: NSRange(location: index, length: end - index), kind: isKey ? .key : .string))
                index = end
            } else if unit == .minus || isDigit(unit) {
                var end = index + 1
                while end < count, isDigit(units[end]) || units[end] == .dot || units[end] == .lowerE || units[end] == .upperE
                    || units[end] == .plus || units[end] == .minus {
                    end += 1
                }
                spans.append(Span(range: NSRange(location: index, length: end - index), kind: .number))
                index = end
            } else if isLetter(unit) {
                var end = index + 1
                while end < count, isLetter(units[end]) { end += 1 }
                let word = String(decoding: units[index..<end], as: UTF16.self)
                if word == "true" || word == "false" || word == "null" {
                    spans.append(Span(range: NSRange(location: index, length: end - index), kind: .keyword))
                }
                index = end
            } else {
                index += 1
            }
        }
        return spans
    }

    /// The index just past the closing quote of the string starting at `start` (or the end of the text).
    private static func endOfString(_ units: [UInt16], from start: Int) -> Int {
        var index = start + 1
        while index < units.count {
            switch units[index] {
            case .backslash: index += 2
            case .quote: return index + 1
            default: index += 1
            }
        }
        return units.count
    }

    // MARK: XML

    private static let commentOpen = Array("<!--".utf16)
    private static let commentClose = Array("-->".utf16)
    private static let cdataOpen = Array("<![CDATA[".utf16)
    private static let cdataClose = Array("]]>".utf16)
    private static let processingClose = Array("?>".utf16)

    private static func xml(_ units: [UInt16]) -> [Span] {
        var spans: [Span] = []
        let count = units.count
        var index = 0
        while index < count {
            guard units[index] == .lessThan else {
                index += 1
                continue
            }
            if hasPrefix(units, commentOpen, at: index) {
                let end = find(units, commentClose, from: index + commentOpen.count).map { $0 + commentClose.count } ?? count
                spans.append(Span(range: NSRange(location: index, length: end - index), kind: .comment))
                index = end
            } else if hasPrefix(units, cdataOpen, at: index) {
                let end = find(units, cdataClose, from: index + cdataOpen.count).map { $0 + cdataClose.count } ?? count
                spans.append(Span(range: NSRange(location: index, length: end - index), kind: .cdata))
                index = end
            } else if index + 1 < count, units[index + 1] == .question {
                let end = find(units, processingClose, from: index + 2).map { $0 + processingClose.count } ?? count
                spans.append(Span(range: NSRange(location: index, length: end - index), kind: .tag))
                index = end
            } else {
                index = tag(units, from: index, into: &spans)
            }
        }
        return spans
    }

    /// `<name attr="value" …>`: the opening (`<name`, `</name`), attributes, values and the closing (`>` / `/>`).
    private static func tag(_ units: [UInt16], from start: Int, into spans: inout [Span]) -> Int {
        let count = units.count
        var index = start + 1
        if index < count, units[index] == .slash { index += 1 }
        while index < count, isNameUnit(units[index]) { index += 1 }
        spans.append(Span(range: NSRange(location: start, length: index - start), kind: .tag))
        while index < count {
            let unit = units[index]
            if unit == .greaterThan || (unit == .slash && index + 1 < count && units[index + 1] == .greaterThan) {
                let length = unit == .greaterThan ? 1 : 2
                spans.append(Span(range: NSRange(location: index, length: length), kind: .tag))
                return index + length
            } else if unit == .quote || unit == .apostrophe {
                var end = index + 1
                while end < count, units[end] != unit { end += 1 }
                end = min(count, end + 1)
                spans.append(Span(range: NSRange(location: index, length: end - index), kind: .string))
                index = end
            } else if isNameUnit(unit) {
                var end = index + 1
                while end < count, isNameUnit(units[end]) { end += 1 }
                spans.append(Span(range: NSRange(location: index, length: end - index), kind: .attribute))
                index = end
            } else if unit == .lessThan {
                // A stray `<` inside a tag starts the next tag.
                return index
            } else {
                index += 1
            }
        }
        return count
    }

    private static func hasPrefix(_ units: [UInt16], _ prefix: [UInt16], at index: Int) -> Bool {
        guard index + prefix.count <= units.count else { return false }
        for offset in prefix.indices where units[index + offset] != prefix[offset] { return false }
        return true
    }

    private static func find(_ units: [UInt16], _ needle: [UInt16], from start: Int) -> Int? {
        guard !needle.isEmpty, start <= units.count - needle.count else { return nil }
        var index = start
        while index <= units.count - needle.count {
            if hasPrefix(units, needle, at: index) { return index }
            index += 1
        }
        return nil
    }

    private static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D }
    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
    private static func isLetter(_ unit: UInt16) -> Bool { (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x41 && unit <= 0x5A) }
    private static func isNameUnit(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit) || unit == .colon || unit == .minus || unit == .dot || unit == 0x5F
    }
}

private extension UInt16 {
    static let quote = UInt16(UInt8(ascii: "\""))
    static let apostrophe = UInt16(UInt8(ascii: "'"))
    static let backslash = UInt16(UInt8(ascii: "\\"))
    static let colon = UInt16(UInt8(ascii: ":"))
    static let minus = UInt16(UInt8(ascii: "-"))
    static let plus = UInt16(UInt8(ascii: "+"))
    static let dot = UInt16(UInt8(ascii: "."))
    static let lowerE = UInt16(UInt8(ascii: "e"))
    static let upperE = UInt16(UInt8(ascii: "E"))
    static let lessThan = UInt16(UInt8(ascii: "<"))
    static let greaterThan = UInt16(UInt8(ascii: ">"))
    static let slash = UInt16(UInt8(ascii: "/"))
    static let question = UInt16(UInt8(ascii: "?"))
}
