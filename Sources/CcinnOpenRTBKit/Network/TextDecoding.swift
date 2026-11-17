import Foundation

/// Turns response bodies into text without ever failing: BOMs, the HTTP charset, the XML declaration, UTF-8, then
/// Latin-1 (which maps every byte) as the last resort.
public enum TextDecoding {
    public static func string(from data: Data, charset: String? = nil) -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return stripBOM(text) }
        }
        if let encoding = (charset ?? xmlDeclaredEncoding(data)).flatMap(encoding(named:)), let text = String(data: data, encoding: encoding) {
            return stripBOM(text)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    /// Whether a body is worth showing as text.
    public static func isTextual(mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        if mimeType.hasPrefix("text/") { return true }
        return ["json", "xml", "javascript", "ecmascript", "x-www-form-urlencoded", "html", "vast", "vmap"].contains { mimeType.contains($0) }
    }

    private static func stripBOM(_ text: String) -> String {
        text.first == "\u{FEFF}" ? String(text.dropFirst()) : text
    }

    /// `encoding="…"` from an `<?xml …?>` declaration in the first bytes.
    static func xmlDeclaredEncoding(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(200), as: UTF8.self)
        guard head.hasPrefix("<?xml"), let end = head.range(of: "?>") else { return nil }
        let declaration = head[..<end.lowerBound]
        guard let key = declaration.range(of: "encoding") else { return nil }
        let rest = declaration[key.upperBound...].drop { $0 == " " || $0 == "=" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        let value = rest.dropFirst().prefix { $0 != quote }
        return value.isEmpty ? nil : value.lowercased()
    }

    static func encoding(named name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8": .utf8
        case "iso-8859-1", "latin1", "latin-1", "us-ascii", "ascii": .isoLatin1
        case "windows-1252", "cp1252": .windowsCP1252
        case "utf-16", "utf16": .utf16
        case "utf-16le": .utf16LittleEndian
        case "utf-16be": .utf16BigEndian
        case "shift_jis", "shift-jis", "sjis": .shiftJIS
        case "euc-jp": .japaneseEUC
        default: nil
        }
    }
}
