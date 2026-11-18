import Foundation

/// One pass over JSON text before Foundation parses it: counts the arrays and objects open at once (brackets inside
/// strings excluded) and, when a container opens past the limit, says where as an RFC 6901 pointer. It tracks only
/// what that pointer needs, the current member name (as a byte range, decoded on failure only) or element index of
/// each open container, so memory is bounded by the limit and the common case allocates one small array.
///
/// A raw NUL byte stops the scan: it is never valid JSON (RFC 8259 §7: control characters must be escaped), and at
/// the start of a document it makes Foundation read the bytes as UTF-16/32, where brackets need not be the bytes this
/// scan counts.
enum JSONNestingScan {
    enum Outcome: Equatable {
        case acceptable
        /// The first array or object opening past the limit is at `pointer`.
        case nestedTooDeeply(pointer: String)
        case nulByte(offset: Int)
    }

    /// An array or object that is open at the current byte.
    private struct OpenContainer {
        let isObject: Bool
        /// Arrays: the index of the element being read.
        var elementIndex = 0
        /// Objects: the current member name's bytes, quotes included.
        var memberName: Range<Int>?
        /// Objects: the next string is a member name.
        var expectsMemberName = true
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")

    static func run(_ bytes: UnsafeRawBufferPointer, limit: Int) -> Outcome {
        var open: [OpenContainer] = []
        open.reserveCapacity(min(max(limit, 0), 256))
        var inString = false
        var escaped = false
        var stringStart = 0
        var stringIsMemberName = false
        for offset in 0..<bytes.count {
            let byte = bytes[offset]
            if byte == 0 { return .nulByte(offset: offset) }
            if inString {
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                    if stringIsMemberName, let top = open.indices.last { open[top].memberName = stringStart..<(offset + 1) }
                }
                continue
            }
            switch byte {
            case quote:
                inString = true
                stringStart = offset
                stringIsMemberName = open.last.map { $0.isObject && $0.expectsMemberName } ?? false
            case UInt8(ascii: ":"):
                if let top = open.indices.last, open[top].isObject { open[top].expectsMemberName = false }
            case UInt8(ascii: ","):
                guard let top = open.indices.last else { break }
                if open[top].isObject {
                    open[top].expectsMemberName = true
                    open[top].memberName = nil
                } else {
                    open[top].elementIndex += 1
                }
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                guard open.count < limit else { return .nestedTooDeeply(pointer: pointer(to: open, in: bytes)) }
                open.append(OpenContainer(isObject: byte == UInt8(ascii: "{")))
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if !open.isEmpty { open.removeLast() }
            default:
                break
            }
        }
        return .acceptable
    }

    /// The location of the value being read inside the innermost open container. A malformed document can leave a
    /// member name unknown (`{{`); its token is then empty.
    private static func pointer(to open: [OpenContainer], in bytes: UnsafeRawBufferPointer) -> String {
        var pointer = JSONPointer.root
        for container in open {
            if container.isObject {
                pointer = pointer.appending(container.memberName.map { memberName(bytes[$0]) } ?? "")
            } else {
                pointer = pointer.appending(container.elementIndex)
            }
        }
        return pointer.description
    }

    /// A member name from its quoted bytes. Escapes (`\/`, `\u00e9`) are decoded by Foundation: a lone string cannot nest.
    private static func memberName(_ quoted: Slice<UnsafeRawBufferPointer>) -> String {
        let unquoted = quoted.dropFirst().dropLast()
        guard unquoted.contains(backslash) else { return String(decoding: unquoted, as: UTF8.self) }
        let decoded = try? JSONSerialization.jsonObject(with: Data(quoted), options: [.fragmentsAllowed])
        return decoded as? String ?? String(decoding: unquoted, as: UTF8.self)
    }
}
