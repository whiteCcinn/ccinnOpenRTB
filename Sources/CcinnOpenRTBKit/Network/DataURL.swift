import Foundation

/// RFC 2397 `data:` URLs, decoded locally (the offline samples use them for VAST wrapper chains and images).
public enum DataURL {
    public struct Decoded: Sendable, Hashable {
        public var data: Data
        /// Defaults to `text/plain` as RFC 2397 says.
        public var mimeType: String
        public var charset: String?
    }

    /// Upper bound for a decoded payload (the URL itself is already in memory; this caps the copy).
    public static let maxDecodedBytes = 32 << 20

    public static func isDataURL(_ string: String) -> Bool {
        string.utf8.prefix(5).map { $0 | 0x20 } == Array("data:".utf8)
    }

    /// Decodes `data:[<mediatype>][;base64],<data>`. Whitespace inside base64 is ignored, missing padding and the
    /// URL-safe alphabet are accepted. Returns `nil` for anything malformed.
    public static func decode(_ string: String) -> Decoded? {
        guard isDataURL(string) else { return nil }
        let body = string.dropFirst(5)
        guard let comma = body.firstIndex(of: ",") else { return nil }
        let header = body[..<comma]
        let payload = body[body.index(after: comma)...]

        var parameters = header.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let isBase64 = parameters.last?.lowercased() == "base64"
        if isBase64 { parameters.removeLast() }
        let declaredType = parameters.first.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let charset = parameters.dropFirst().compactMap { parameter -> String? in
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "charset" else { return nil }
            return pair[1].lowercased()
        }.first
        let mimeType = declaredType.flatMap { $0.contains("/") ? $0 : nil } ?? "text/plain"

        let data: Data?
        if isBase64 {
            let percentDecoded = String(payload).removingPercentEncoding ?? String(payload)
            data = base64(percentDecoded)
        } else {
            data = percentDecode(payload)
        }
        guard let data, data.count <= maxDecodedBytes else { return nil }
        return Decoded(data: data, mimeType: mimeType, charset: charset ?? (declaredType == nil ? "us-ascii" : nil))
    }

    /// `data:<mime>;base64,<payload>`.
    public static func make(_ data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private static func base64(_ text: String) -> Data? {
        var cleaned = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        cleaned = cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = cleaned.utf8.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: cleaned)
    }

    /// Percent-decoding that keeps invalid escapes verbatim instead of failing.
    private static func percentDecode(_ text: Substring) -> Data? {
        let bytes = Array(text.utf8)
        var output = Data()
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count, let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
            if output.count > maxDecodedBytes { return nil }
        }
        return output
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
