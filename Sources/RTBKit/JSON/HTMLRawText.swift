import Foundation

/// Where an HTML raw-text element (`script`, `style`, `textarea` …) ends, as a browser reads it (pure, linear).
///
/// A `script` follows the HTML "script data" states: after `<!--`, a `<script` inside it makes the next `</script` its
/// own, until `-->` — so a legacy `<script><!-- document.write('<script …></script>') //--></script>` is one element.
/// Other raw-text elements end at the first `</name`.
public enum HTMLRawText {
    /// The index of the `<` of the end tag `</name` (followed by whitespace, `/`, `>` or the end), searching `bytes` from
    /// `start`; `nil` when there is none. `name` is lower-case ASCII.
    public static func endTagStart(of name: String, in bytes: ArraySlice<UInt8>, from start: Int) -> Int? {
        let pattern = Array(name.utf8)
        let end = bytes.endIndex
        let isScript = name == "script"
        var state = State.data
        var index = max(start, bytes.startIndex)
        while index < end {
            let byte = bytes[index]
            if isScript, byte == UInt8(ascii: "-"), state != .data, hasPrefix(bytes, at: index, "-->") {
                state = .data
                index += 3
                continue
            }
            guard byte == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            if isScript, state == .data, hasPrefix(bytes, at: index, "<!--") {
                state = .escaped
                index += 4
                continue
            }
            if index + 1 < end, bytes[index + 1] == UInt8(ascii: "/"), isTag(bytes, at: index + 2, pattern) {
                guard state == .doubleEscaped else { return index }
                state = .escaped
                index += 2 + pattern.count
                continue
            }
            if state == .escaped, isTag(bytes, at: index + 1, pattern) {
                state = .doubleEscaped
                index += 1 + pattern.count
                continue
            }
            index += 1
        }
        return nil
    }

    private enum State {
        case data, escaped, doubleEscaped
    }

    /// `pattern` (lower-case) at `index`, case-insensitively, followed by whitespace, `/`, `>` or the end.
    private static func isTag(_ bytes: ArraySlice<UInt8>, at index: Int, _ pattern: [UInt8]) -> Bool {
        guard index >= bytes.startIndex, index + pattern.count <= bytes.endIndex else { return false }
        for offset in 0..<pattern.count {
            var byte = bytes[index + offset]
            if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { byte += 32 }
            guard byte == pattern[offset] else { return false }
        }
        let after = index + pattern.count
        guard after < bytes.endIndex else { return true }
        let next = bytes[after]
        return next == UInt8(ascii: " ") || next == UInt8(ascii: "\t") || next == UInt8(ascii: "\n") || next == UInt8(ascii: "\r")
            || next == 0x0C || next == UInt8(ascii: "/") || next == UInt8(ascii: ">")
    }

    private static func hasPrefix(_ bytes: ArraySlice<UInt8>, at index: Int, _ prefix: String) -> Bool {
        let pattern = Array(prefix.utf8)
        guard index + pattern.count <= bytes.endIndex else { return false }
        return bytes[index..<(index + pattern.count)].elementsEqual(pattern)
    }
}
