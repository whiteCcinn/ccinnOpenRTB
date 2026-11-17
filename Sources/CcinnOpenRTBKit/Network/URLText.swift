import Foundation

/// URL helpers that work on tracker templates too (`[ERRORCODE]`, `${AUCTION_PRICE}` make `URLComponents` fail).
public enum URLText {
    /// `host` + `path` for the table ("ads.example.com/imp"); the whole string when it is not a hierarchical URL.
    public static func hostAndPath(_ url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return url }
        var rest = url[schemeEnd.upperBound...]
        if let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        if let at = rest[..<authorityEnd].lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        return String(rest)
    }

    /// The lowercased host, if any.
    public static func host(_ url: String) -> String? {
        let hostAndPath = hostAndPath(url)
        guard url.contains("://") else { return nil }
        let authority = hostAndPath.prefix { $0 != "/" }
        if authority.hasPrefix("[") { return authority.split(separator: "]").first.map { String($0.dropFirst()).lowercased() } }
        return authority.split(separator: ":").first.map { $0.lowercased() }
    }

    /// The lowercased scheme, if any.
    public static func scheme(_ url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let scheme = url[..<colon]
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }) else { return nil }
        return scheme.lowercased()
    }

    /// Query parameters in order, percent-decoded where possible (`+` is kept: trackers rarely mean a space by it).
    public static func queryItems(_ url: String) -> [(name: String, value: String)] {
        guard let question = url.firstIndex(of: "?") else { return [] }
        var query = url[url.index(after: question)...]
        if let hash = query.firstIndex(of: "#") { query = query[..<hash] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            return (name: name.removingPercentEncoding ?? name, value: value.removingPercentEncoding ?? value)
        }
    }

    /// A `URL` for the transport. Characters a template may still contain (unknown macros' `[ ]`, spaces, `{ }`, `|`)
    /// are percent-encoded instead of making the request impossible.
    public static func requestURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil { return url }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        guard let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: escaped), url.scheme != nil, url.host != nil else { return nil }
        return url
    }
}

/// Finds OpenRTB `${MACRO}` (incl. `${MACRO:B64}`) and VAST `[MACRO]` placeholders, for highlighting.
public enum MacroTokens {
    public struct Token: Sendable, Hashable {
        public var range: Range<String.Index>
        /// The macro as written: `${AUCTION_PRICE}`, `[ERRORCODE]`.
        public var text: String
    }

    public static func find(in text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "$", text[index...].hasPrefix("${"), let close = text[index...].firstIndex(of: "}") {
                let name = text[text.index(index, offsetBy: 2)..<close]
                if !name.isEmpty, name.count <= 64, name.allSatisfy(isOpenRTBMacroCharacter) {
                    let end = text.index(after: close)
                    tokens.append(Token(range: index..<end, text: String(text[index..<end])))
                    index = end
                    continue
                }
            } else if character == "[", let close = text[index...].firstIndex(of: "]") {
                let name = text[text.index(after: index)..<close]
                if !name.isEmpty, name.count <= 64, name.allSatisfy(isVASTMacroCharacter), name.contains(where: \.isLetter) {
                    let end = text.index(after: close)
                    tokens.append(Token(range: index..<end, text: String(text[index..<end])))
                    index = end
                    continue
                }
            }
            index = text.index(after: index)
        }
        return tokens
    }

    private static func isOpenRTBMacroCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isUppercase || character.isNumber || character == "_" || character == ":" || character.isLowercase)
    }

    private static func isVASTMacroCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isUppercase || character.isNumber || character == "_")
    }
}
