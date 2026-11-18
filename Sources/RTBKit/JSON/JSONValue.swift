import Foundation

/// A JSON value with lossless integers and a single-line serializer (MCP stdio framing).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public struct ParseError: Error, CustomStringConvertible, Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            /// Not well-formed JSON; `detail` says why.
            case malformed(detail: String)
            /// An array or object opens deeper than `JSONValue.maxNestingDepth`; `pointer` (RFC 6901) locates the first.
            case nestedTooDeeply(pointer: String)
        }

        public let reason: Reason

        public init(reason: Reason) {
            self.reason = reason
        }

        public var description: String {
            switch reason {
            case let .malformed(detail): "Invalid JSON: \(detail)"
            case .nestedTooDeeply: "Nested too deeply: more than \(JSONValue.maxNestingDepth) levels of arrays and objects."
            }
        }
    }

    // MARK: Parsing

    /// The most arrays and objects open at once that `parse` accepts. JSONSerialization recurses once per level and
    /// overflows a 512 KB thread stack (Swift concurrency's cooperative pool) at roughly 500 nested objects, so deeper
    /// input is rejected before Foundation sees it.
    public static let maxNestingDepth = 128

    public static func parse(_ text: String) throws(ParseError) -> JSONValue {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws(ParseError) -> JSONValue {
        switch data.withUnsafeBytes({ JSONNestingScan.run($0, limit: maxNestingDepth) }) {
        case .acceptable:
            break
        case let .nestedTooDeeply(pointer):
            throw ParseError(reason: .nestedTooDeeply(pointer: pointer))
        case let .nulByte(offset):
            throw ParseError(reason: .malformed(detail: "a NUL byte at offset \(offset); control characters must be escaped."))
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ParseError(reason: .malformed(detail: error.localizedDescription))
        }
        return try convert(object, depth: 0)
    }

    /// `depth` is the number of arrays and objects around `object`. `JSONNestingScan` already bounds it; the guard
    /// keeps this recursion bounded on its own.
    private static func convert(_ object: Any, depth: Int) throws(ParseError) -> JSONValue {
        guard depth <= maxNestingDepth else {
            throw ParseError(reason: .malformed(detail: "nested deeper than \(maxNestingDepth) levels."))
        }
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let type = String(cString: number.objCType)
            if ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type), !(number is NSDecimalNumber) {
                if type == "Q", number.uint64Value > UInt64(Int64.max) { return .double(number.doubleValue) }
                return .int(number.int64Value)
            }
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < 9.007_199_254_740_992e15, number is NSDecimalNumber {
                return .int(Int64(double))
            }
            return .double(double)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            var values: [JSONValue] = []
            values.reserveCapacity(array.count)
            for element in array { values.append(try convert(element, depth: depth + 1)) }
            return .array(values)
        case let dictionary as [String: Any]:
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(dictionary.count)
            for (key, value) in dictionary { result[key] = try convert(value, depth: depth + 1) }
            return .object(result)
        default:
            throw ParseError(reason: .malformed(detail: "an unsupported value."))
        }
    }

    // MARK: Serialization

    /// Compact, single-line JSON with sorted object keys.
    public func serialized() -> String {
        var output = ""
        write(into: &output)
        return output
    }

    private func write(into output: inout String) {
        switch self {
        case .null: output += "null"
        case let .bool(value): output += value ? "true" : "false"
        case let .int(value): output += String(value)
        case let .double(value):
            if value.isFinite {
                if value.rounded() == value, abs(value) < 1e15 { output += String(Int64(value)) } else { output += "\(value)" }
            } else {
                output += "null"
            }
        case let .string(value): Self.writeString(value, into: &output)
        case let .array(values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                value.write(into: &output)
            }
            output += "]"
        case let .object(members):
            output += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                Self.writeString(key, into: &output)
                output += ":"
                members[key]?.write(into: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\u{2028}": output += "\\u2028"
            case "\u{2029}": output += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        if case let .object(members) = self { return members[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case let .array(values) = self, values.indices.contains(index) { return values[index] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case let .int(value): return value
        case let .double(value) where value.isFinite && value.rounded() == value && abs(value) < 9.2e18: return Int64(value)
        case let .string(value): return Int64(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .int(value): return Double(value)
        case let .double(value): return value
        case let .string(value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case let .bool(value): return value
        case let .string(value): return ["true", "1", "yes"].contains(value.lowercased()) ? true : (["false", "0", "no"].contains(value.lowercased()) ? false : nil)
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(values) = self { return values }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(members) = self { return members }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    public init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
    public init(_ value: Int64?) { self = value.map(JSONValue.int) ?? .null }
    public init(_ value: Int?) { self = value.map { .int(Int64($0)) } ?? .null }
    public init(_ value: Double?) { self = value.map { $0.isFinite ? .double($0) : .null } ?? .null }
    public init(_ value: Bool?) { self = value.map(JSONValue.bool) ?? .null }
}

/// Splits a byte stream into newline-delimited messages with a bounded line length.
public struct LineFramer: Sendable {
    public enum Event: Sendable, Equatable {
        case line(String)
        /// A line longer than the limit was discarded.
        case oversized
    }

    public let maxLineBytes: Int
    private var buffer: [UInt8] = []
    private var discarding = false

    public init(maxLineBytes: Int = 4 * 1024 * 1024) {
        self.maxLineBytes = max(16, maxLineBytes)
    }

    public mutating func append(_ bytes: [UInt8]) -> [Event] {
        var events: [Event] = []
        for byte in bytes {
            if byte == 0x0A {
                if discarding {
                    discarding = false
                } else {
                    if buffer.last == 0x0D { buffer.removeLast() }
                    if !buffer.isEmpty {
                        events.append(.line(String(decoding: buffer, as: UTF8.self)))
                    }
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            guard !discarding else { continue }
            buffer.append(byte)
            if buffer.count > maxLineBytes {
                buffer.removeAll()
                discarding = true
                events.append(.oversized)
            }
        }
        return events
    }
}
