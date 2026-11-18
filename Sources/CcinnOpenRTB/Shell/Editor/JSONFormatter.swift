import Foundation

/// Pretty-prints JSON by re-indenting its tokens (pure, linear, byte-level). Unlike a decode / encode round trip it keeps
/// key order, number spelling (`1.50`), escapes and unknown fields exactly as pasted — what an ad-tech engineer needs
/// when comparing a response with logs.
enum JSONFormatter {
    /// `nil` when `text` is not a single JSON object or array with balanced brackets and terminated strings.
    static func prettyPrinted(_ text: String, indentWidth: Int = 2) -> String? {
        let bytes = Array(text.utf8)
        let count = bytes.count
        var index = 0
        while index < count, isWhitespace(bytes[index]) { index += 1 }
        guard index < count, bytes[index] == .openBrace || bytes[index] == .openBracket else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(count + count / 3)
        var stack: [UInt8] = []
        var inString = false
        var escaped = false
        var closedTopLevel = false

        func newline(depth: Int) {
            output.append(.newline)
            output.append(contentsOf: repeatElement(UInt8.space, count: depth * indentWidth))
        }

        while index < count {
            let byte = bytes[index]
            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == .backslash {
                    escaped = true
                } else if byte == .quote {
                    inString = false
                }
                index += 1
                continue
            }
            if isWhitespace(byte) {
                index += 1
                continue
            }
            // Only whitespace may follow the top-level value.
            if closedTopLevel { return nil }
            switch byte {
            case .quote:
                inString = true
                output.append(byte)
            case .openBrace, .openBracket:
                let close: UInt8 = byte == .openBrace ? .closeBrace : .closeBracket
                var next = index + 1
                while next < count, isWhitespace(bytes[next]) { next += 1 }
                if next < count, bytes[next] == close {
                    // An empty container stays on one line: {} / [].
                    output.append(byte)
                    output.append(close)
                    index = next + 1
                    if stack.isEmpty { closedTopLevel = true }
                    continue
                }
                stack.append(byte)
                output.append(byte)
                newline(depth: stack.count)
            case .closeBrace, .closeBracket:
                guard let open = stack.popLast(), (open == .openBrace ? UInt8.closeBrace : .closeBracket) == byte else { return nil }
                newline(depth: stack.count)
                output.append(byte)
                if stack.isEmpty { closedTopLevel = true }
            case .comma:
                guard !stack.isEmpty else { return nil }
                output.append(byte)
                newline(depth: stack.count)
            case .colon:
                output.append(byte)
                output.append(.space)
            default:
                output.append(byte)
            }
            index += 1
        }
        guard !inString, stack.isEmpty, closedTopLevel else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == .space || byte == .newline || byte == 0x09 || byte == 0x0D
    }
}

private extension UInt8 {
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let comma = UInt8(ascii: ",")
    static let colon = UInt8(ascii: ":")
    static let space = UInt8(ascii: " ")
    static let newline = UInt8(ascii: "\n")
}
