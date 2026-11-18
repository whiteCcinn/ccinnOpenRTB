import Foundation

/// The resource URLs an HTML fragment names in its start tags, tokenised the way an HTML parser reads attributes
/// (WHATWG HTML §13.2.5: tag open, attribute name, before / after attribute value; double-quoted, single-quoted and
/// unquoted values; character references decoded). Script and style element contents are raw text, never scanned for
/// tags. Pure and bounded: at most `maxURLs` results, input capped at `maxInput` characters.
enum HTMLResourceScanner {
    static let maxURLs = 200
    static let maxInput = 512 * 1024

    /// Elements that load what an attribute names, and those attributes.
    private static let resourceAttributes: [String: Set<String>] = [
        "script": ["src"], "img": ["src"], "iframe": ["src"], "frame": ["src"], "embed": ["src"], "source": ["src"],
        "track": ["src"], "audio": ["src"], "video": ["src", "poster"], "input": ["src"], "object": ["data"], "link": ["href"],
    ]
    private static let rawTextElements: Set<String> = ["script", "style"]

    static func resourceURLs(in html: String) -> [String] {
        let characters = Array(html.prefix(maxInput).unicodeScalars)
        var urls: [String] = []
        var index = 0
        while index < characters.count, urls.count < maxURLs {
            guard characters[index] == "<", index + 1 < characters.count, isASCIILetter(characters[index + 1]) else {
                index += 1
                continue
            }
            var cursor = index + 1
            let name = readName(characters, &cursor).lowercased()
            let attributes = readAttributes(characters, &cursor)
            if let wanted = resourceAttributes[name] {
                for (attribute, value) in attributes where wanted.contains(attribute) {
                    let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !url.isEmpty { urls.append(url) }
                }
            }
            if rawTextElements.contains(name) {
                cursor = endOfRawText(characters, from: cursor, element: name)
            }
            index = max(cursor, index + 1)
        }
        return urls
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}"
    }

    private static func readName(_ characters: [Unicode.Scalar], _ cursor: inout Int) -> String {
        var name = String.UnicodeScalarView()
        while cursor < characters.count, !isSpace(characters[cursor]), characters[cursor] != "/", characters[cursor] != ">" {
            name.append(characters[cursor])
            cursor += 1
        }
        return String(name)
    }

    /// Attributes up to the tag's `>` (lower-cased names, decoded values); `cursor` ends after the `>`.
    private static func readAttributes(_ characters: [Unicode.Scalar], _ cursor: inout Int) -> [(String, String)] {
        var attributes: [(String, String)] = []
        while cursor < characters.count {
            while cursor < characters.count, isSpace(characters[cursor]) || characters[cursor] == "/" { cursor += 1 }
            guard cursor < characters.count else { break }
            if characters[cursor] == ">" {
                cursor += 1
                break
            }
            var name = String.UnicodeScalarView()
            while cursor < characters.count, !isSpace(characters[cursor]), characters[cursor] != "=", characters[cursor] != ">",
                  characters[cursor] != "/" || name.isEmpty {
                name.append(characters[cursor])
                cursor += 1
            }
            while cursor < characters.count, isSpace(characters[cursor]) { cursor += 1 }
            var value = ""
            if cursor < characters.count, characters[cursor] == "=" {
                cursor += 1
                while cursor < characters.count, isSpace(characters[cursor]) { cursor += 1 }
                if cursor < characters.count, characters[cursor] == "\"" || characters[cursor] == "'" {
                    let quote = characters[cursor]
                    cursor += 1
                    var raw = String.UnicodeScalarView()
                    while cursor < characters.count, characters[cursor] != quote {
                        raw.append(characters[cursor])
                        cursor += 1
                    }
                    guard cursor < characters.count else { return attributes }  // unterminated: not a tag
                    cursor += 1
                    value = decodeReferences(String(raw))
                } else {
                    var raw = String.UnicodeScalarView()
                    while cursor < characters.count, !isSpace(characters[cursor]), characters[cursor] != ">" {
                        raw.append(characters[cursor])
                        cursor += 1
                    }
                    value = decodeReferences(String(raw))
                }
            }
            if !name.isEmpty { attributes.append((String(name).lowercased(), value)) }
        }
        return attributes
    }

    /// The index after `</element` … `>`, or the end.
    private static func endOfRawText(_ characters: [Unicode.Scalar], from start: Int, element: String) -> Int {
        let closing = Array(("</" + element).unicodeScalars)
        var index = start
        while index + closing.count <= characters.count {
            var matches = true
            for (offset, scalar) in closing.enumerated() where String(characters[index + offset]).lowercased() != String(scalar) {
                matches = false
                break
            }
            if matches {
                var end = index + closing.count
                while end < characters.count, characters[end] != ">" { end += 1 }
                return min(characters.count, end + 1)
            }
            index += 1
        }
        return characters.count
    }

    private static let namedReferences: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "sol": "/", "colon": ":", "period": ".", "quest": "?",
        "equals": "=", "num": "#", "percnt": "%", "plus": "+", "lowbar": "_", "hyphen": "-", "commat": "@", "nbsp": "\u{00A0}",
    ]

    /// Decodes numeric (`&#47;`, `&#x2F;`) and common named character references; anything else stays as written.
    static func decodeReferences(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semicolon = after.prefix(12).firstIndex(of: ";") else {
                result += "&"
                rest = after
                continue
            }
            let body = after[..<semicolon]
            if let decoded = decode(String(body)) {
                result += decoded
                rest = after[after.index(after: semicolon)...]
            } else {
                result += "&"
                rest = after
            }
        }
        return result + rest
    }

    private static func decode(_ body: String) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        if body.hasPrefix("#") {
            return UInt32(body.dropFirst(), radix: 10).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        return namedReferences[body]
    }
}
