import Foundation

/// Turns an HTML `adm` into the document the web view loads.
enum HTMLDocumentBuilder {
    /// Stops WebKit from resolving host names of links the creative contains (DNS leaves the machine even when HTTP is blocked).
    static let dnsPrefetchOff = #"<meta http-equiv="x-dns-prefetch-control" content="off">"#

    /// A fragment is wrapped in a minimal document (viewport meta, zero margins); a full document gets only the DNS-prefetch
    /// switch, right after its prolog (doctype, comments). There the HTML parser (WHATWG §13.2.6.4.2 "before html")
    /// creates the head for it, and the creative's own `<html>` / `<head>` merge into those: the switch is the head's first
    /// element, read before any link, and the doctype still decides the rendering mode. It never lands inside a comment, a
    /// script or an attribute value that merely contains "<head".
    static func document(for adm: String) -> String {
        let prolog = Prolog(adm)
        guard prolog.isFullDocument else {
            return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width, initial-scale=1">\
            \(dnsPrefetchOff)\
            <style>html,body{margin:0;padding:0;}</style></head>
            <body>\(adm)</body></html>
            """
        }
        let scalars = adm.unicodeScalars
        var document = String.UnicodeScalarView()
        document.append(contentsOf: scalars[..<prolog.end])
        document.append(contentsOf: dnsPrefetchOff.unicodeScalars)
        document.append(contentsOf: scalars[prolog.end...])
        return String(document)
    }

    /// A full document: one with a doctype, or whose first element (after whitespace and comments) is `<html>` or `<head>`.
    static func isFullDocument(_ adm: String) -> Bool {
        Prolog(adm).isFullDocument
    }

    /// The document's prolog as the HTML tokenizer reads it in the "initial" insertion mode: whitespace, comments (including
    /// `<!-->`, `<!--->`, `--!>` endings and the bogus comments `<?…>` and `<!…>`) and the doctype.
    private struct Prolog {
        /// Where the prolog's last token ends (the start of the input when it has none or one never closes).
        private(set) var end: String.UnicodeScalarView.Index
        private(set) var isFullDocument = false

        init(_ markup: String) {
            let scalars = markup.unicodeScalars
            end = scalars.startIndex
            var cursor = scalars.startIndex
            var hasDoctype = false
            while true {
                while cursor < scalars.endIndex, Self.isSpace(scalars[cursor]) { cursor = scalars.index(after: cursor) }
                guard cursor < scalars.endIndex, scalars[cursor] == "<" else { break }
                let rest = scalars[cursor...]
                let tokenEnd: String.UnicodeScalarView.Index?
                if Self.hasPrefix(rest, "<!--") {
                    tokenEnd = Self.commentEnd(scalars, from: scalars.index(cursor, offsetBy: 4))
                } else if Self.hasPrefix(rest, "<!doctype", caseInsensitive: true) {
                    tokenEnd = Self.index(after: ">", in: scalars, from: cursor)
                    hasDoctype = true
                } else if Self.hasPrefix(rest, "<!") || Self.hasPrefix(rest, "<?") {
                    tokenEnd = Self.index(after: ">", in: scalars, from: cursor)
                } else {
                    isFullDocument = hasDoctype || Self.isStartTag(rest, named: "html") || Self.isStartTag(rest, named: "head")
                    return
                }
                guard let tokenEnd else {
                    // Unterminated: the token runs to the end of the input, so nothing after it would be markup.
                    end = scalars.startIndex
                    isFullDocument = hasDoctype
                    return
                }
                cursor = tokenEnd
                end = tokenEnd
            }
            isFullDocument = hasDoctype
        }

        private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" || scalar == "\u{FEFF}"
        }

        private static func hasPrefix(_ scalars: Substring.UnicodeScalarView, _ prefix: String, caseInsensitive: Bool = false) -> Bool {
            var index = scalars.startIndex
            for expected in prefix.unicodeScalars {
                guard index < scalars.endIndex else { return false }
                let actual = scalars[index]
                let matches = caseInsensitive ? lowered(actual) == lowered(expected) : actual == expected
                guard matches else { return false }
                index = scalars.index(after: index)
            }
            return true
        }

        private static func lowered(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
            (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
        }

        /// `<name` followed by whitespace, `/`, `>` or the end (so `<header>` is not `<head>`).
        private static func isStartTag(_ scalars: Substring.UnicodeScalarView, named name: String) -> Bool {
            guard hasPrefix(scalars, "<" + name, caseInsensitive: true) else { return false }
            let after = scalars.index(scalars.startIndex, offsetBy: name.unicodeScalars.count + 1)
            guard after < scalars.endIndex else { return true }
            let next = scalars[after]
            return isSpace(next) || next == "/" || next == ">"
        }

        /// The index after the first `character` at or after `start`; `nil` when there is none.
        private static func index(after character: Unicode.Scalar, in scalars: String.UnicodeScalarView,
                                  from start: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index? {
            guard let found = scalars[start...].firstIndex(of: character) else { return nil }
            return scalars.index(after: found)
        }

        /// The end of a comment whose `<!--` ends just before `start`: `<!-->` and `<!--->` close at once; otherwise the
        /// first `-->` or `--!>`. `nil` when it never closes.
        private static func commentEnd(_ scalars: String.UnicodeScalarView, from start: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index? {
            let body = scalars[start...]
            if hasPrefix(body, ">") { return scalars.index(after: start) }
            if hasPrefix(body, "->") { return scalars.index(start, offsetBy: 2) }
            var cursor = start
            while cursor < scalars.endIndex {
                let rest = scalars[cursor...]
                if hasPrefix(rest, "-->") { return scalars.index(cursor, offsetBy: 3) }
                if hasPrefix(rest, "--!>") { return scalars.index(cursor, offsetBy: 4) }
                cursor = scalars.index(after: cursor)
            }
            return nil
        }
    }
}
