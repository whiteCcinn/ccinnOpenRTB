import Foundation

/// Values embedded in generated JavaScript. Everything that goes into a script source is a JSON literal, so untrusted
/// text (URLs, markup, ad titles) can never break out of its string: quotes and backslashes are escaped by the encoder,
/// `/` becomes `\/` (no `</script>` inside a literal) and the line separators U+2028 / U+2029 are escaped.
enum JSLiteral {
    static func string(_ value: String) -> String {
        json(value)
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
