import Foundation

/// A single HTTP byte range (RFC 9110 §14): `bytes=start-end` (inclusive), `bytes=start-`, or the suffix `bytes=-length`.
struct ByteRange: Sendable, Hashable {
    enum Form: Sendable, Hashable {
        case from(Int64, through: Int64?)
        case suffix(Int64)
    }

    var form: Form

    static func from(_ start: Int64, through end: Int64? = nil) -> ByteRange {
        ByteRange(form: .from(max(0, start), through: end.map { max(max(0, start), $0) }))
    }

    /// The `Range` header value.
    var header: String {
        switch form {
        case let .from(start, end?): "bytes=\(start)-\(end)"
        case let .from(start, nil): "bytes=\(start)-"
        case let .suffix(length): "bytes=-\(length)"
        }
    }

    /// Parses one `Range` header with a single byte range; anything else (several ranges, other units, junk) is `nil`, so
    /// nothing but digits and `-` is ever forwarded.
    init?(header: String) {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && $0.count <= 18 }) else { return nil }
        switch (Int64(parts[0]), Int64(parts[1])) {
        case let (start?, end?) where end >= start: form = .from(start, through: end)
        case let (start?, nil) where parts[1].isEmpty: form = .from(start, through: nil)
        case let (nil, length?) where parts[0].isEmpty && length > 0: form = .suffix(length)
        default: return nil
        }
    }

    private init(form: Form) {
        self.form = form
    }
}

/// A `Content-Range: bytes start-end/total` response header (`total` is `nil` for `*`).
struct ContentRange: Sendable, Hashable {
    var start: Int64
    var end: Int64
    var total: Int64?

    var length: Int64 { end - start + 1 }

    init(start: Int64, end: Int64, total: Int64?) {
        self.start = start
        self.end = end
        self.total = total
    }

    init?(header: String?) {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)), start >= 0, end >= start else { return nil }
        let totalText = parts[1].trimmingCharacters(in: .whitespaces)
        if totalText == "*" {
            total = nil
        } else {
            guard let total = Int64(totalText), total > end else { return nil }
            self.total = total
        }
        self.start = start
        self.end = end
    }

    var header: String { "bytes \(start)-\(end)/\(total.map(String.init) ?? "*")" }
}
