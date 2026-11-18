import Foundation

// Lenient, issue-reporting access to decoded JSON, shared by the OpenRTB, AdCOM and Native parsers.
// Wrong types never fail a parse: a usable value is coerced (with a warning) or the field is treated as absent.

/// Collects validation issues in order.
struct IssueLog {
    private(set) var issues: [ValidationIssue] = []

    mutating func error(_ code: String, _ message: String, at pointer: JSONPointer) {
        issues.append(ValidationIssue(.error, code: code, message: message, path: pointer.description))
    }

    mutating func warning(_ code: String, _ message: String, at pointer: JSONPointer) {
        issues.append(ValidationIssue(.warning, code: code, message: message, path: pointer.description))
    }

    mutating func info(_ code: String, _ message: String, at pointer: JSONPointer) {
        issues.append(ValidationIssue(.info, code: code, message: message, path: pointer.description))
    }

    mutating func append(_ issue: ValidationIssue) {
        issues.append(issue)
    }

    /// Appends issues produced against another document, re-rooting their paths under `pointer`.
    mutating func append(contentsOf other: [ValidationIssue], under pointer: JSONPointer) {
        for issue in other {
            issues.append(ValidationIssue(issue.severity, code: issue.code, message: issue.message,
                                          path: pointer.appending(pointer: issue.path).description))
        }
    }

    /// When `JSONValue.parse` rejected the document at `document` (the root, `request:`, or a string field holding
    /// JSON) for its nesting, logs `code` ("Nested too deeply…", then `outcome`) at the first array or object past the
    /// limit and returns true. Returns false for malformed JSON, which each reader reports in its own words.
    mutating func nestedTooDeeply(_ error: JSONValue.ParseError, code: String, severity: ValidationIssue.Severity, in document: JSONPointer,
                                  outcome: String) -> Bool {
        guard case let .nestedTooDeeply(pointer) = error.reason else { return false }
        issues.append(ValidationIssue(severity, code: code, message: error.description + " " + outcome,
                                      path: document.appending(pointer: pointer).description))
        return true
    }
}

/// A JSON object being read, with its location. Every accessor reports a type mismatch under `<domain>.type.mismatch`.
struct JSONObjectReader {
    let members: [String: JSONValue]
    let pointer: JSONPointer
    /// Code prefix: `openrtb`, `adcom`, `native`, `request`.
    let domain: String

    init(_ members: [String: JSONValue], at pointer: JSONPointer, domain: String) {
        self.members = members
        self.pointer = pointer
        self.domain = domain
    }

    func has(_ key: String) -> Bool {
        guard let value = members[key] else { return false }
        if case .null = value { return false }
        return true
    }

    func raw(_ key: String) -> JSONValue? {
        guard let value = members[key] else { return nil }
        if case .null = value { return nil }
        return value
    }

    // MARK: Scalars

    func string(_ key: String, log: inout IssueLog) -> String? {
        guard let value = raw(key) else { return nil }
        switch value {
        case let .string(text):
            return text
        case let .int(number):
            mismatch(key, expected: "a string", found: value, log: &log)
            return String(number)
        case let .double(number):
            mismatch(key, expected: "a string", found: value, log: &log)
            return MacroEncoding.decimal(number)
        default:
            mismatch(key, expected: "a string", found: value, log: &log)
            return nil
        }
    }

    /// A string that must not be blank; whitespace-only strings count as absent.
    func nonBlankString(_ key: String, log: inout IssueLog) -> String? {
        guard let text = string(key, log: &log) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    func int(_ key: String, log: inout IssueLog) -> Int? {
        guard let value = raw(key) else { return nil }
        switch value {
        case let .int(number):
            guard let converted = Int(exactly: number) else {
                mismatch(key, expected: "an integer", found: value, log: &log)
                return nil
            }
            return converted
        case let .double(number):
            if number.isFinite, number == number.rounded(), abs(number) < 9e15 { return Int(number) }
            mismatch(key, expected: "an integer", found: value, log: &log)
            return nil
        case let .string(text):
            mismatch(key, expected: "an integer", found: value, log: &log)
            return Int(text.trimmingCharacters(in: .whitespaces))
        case let .bool(flag):
            mismatch(key, expected: "an integer", found: value, log: &log)
            return flag ? 1 : 0
        default:
            mismatch(key, expected: "an integer", found: value, log: &log)
            return nil
        }
    }

    /// A finite number; strings holding a number are accepted with a warning.
    func double(_ key: String, log: inout IssueLog) -> Double? {
        guard let value = raw(key) else { return nil }
        switch value {
        case let .int(number):
            return Double(number)
        case let .double(number):
            guard number.isFinite else {
                mismatch(key, expected: "a finite number", found: value, log: &log)
                return nil
            }
            return number
        case let .string(text):
            mismatch(key, expected: "a number", found: value, log: &log)
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
            return number
        default:
            mismatch(key, expected: "a number", found: value, log: &log)
            return nil
        }
    }

    /// `0`/`1` flags (OpenRTB uses integers); booleans are accepted with a warning.
    func flag(_ key: String, log: inout IssueLog) -> Bool? {
        guard let value = raw(key) else { return nil }
        if case let .bool(flag) = value {
            mismatch(key, expected: "0 or 1", found: value, log: &log)
            return flag
        }
        return int(key, log: &log).map { $0 != 0 }
    }

    /// A version written as a string or a number (`"1.2"`, `1.2`, `1`).
    func version(_ key: String, log: inout IssueLog) -> String? {
        guard let value = raw(key) else { return nil }
        switch value {
        case let .string(text): return text
        case let .int(number): return String(number)
        case let .double(number):
            guard number.isFinite else { return nil }
            return number == number.rounded() && abs(number) < 1e6 ? String(Int(number)) + ".0" : "\(number)"
        default:
            mismatch(key, expected: "a version string", found: value, log: &log)
            return nil
        }
    }

    // MARK: Containers

    func object(_ key: String, log: inout IssueLog) -> JSONObjectReader? {
        guard let value = raw(key) else { return nil }
        guard case let .object(members) = value else {
            mismatch(key, expected: "an object", found: value, log: &log)
            return nil
        }
        return JSONObjectReader(members, at: pointer.appending(key), domain: domain)
    }

    /// The objects of an array; non-object elements are reported and skipped. `index` is the element's array index.
    func objects(_ key: String, log: inout IssueLog) -> [(index: Int, reader: JSONObjectReader)]? {
        guard let value = raw(key) else { return nil }
        guard case let .array(elements) = value else {
            if case let .object(members) = value {
                mismatch(key, expected: "an array", found: value, log: &log)
                return [(0, JSONObjectReader(members, at: pointer.appending(key), domain: domain))]
            }
            mismatch(key, expected: "an array of objects", found: value, log: &log)
            return nil
        }
        let arrayPointer = pointer.appending(key)
        var readers: [(index: Int, reader: JSONObjectReader)] = []
        readers.reserveCapacity(elements.count)
        for (index, element) in elements.enumerated() {
            if case let .object(members) = element {
                readers.append((index, JSONObjectReader(members, at: arrayPointer.appending(index), domain: domain)))
            } else {
                log.warning(domain + ".type.mismatch", "Expected an object, found \(Self.describe(element)).", at: arrayPointer.appending(index))
            }
        }
        return readers
    }

    /// An array of strings; a lone string is accepted as a one-element array (with a warning), other elements are skipped.
    func strings(_ key: String, log: inout IssueLog) -> [String]? {
        guard let value = raw(key) else { return nil }
        switch value {
        case let .array(elements):
            var result: [String] = []
            result.reserveCapacity(elements.count)
            let arrayPointer = pointer.appending(key)
            for (index, element) in elements.enumerated() {
                if case let .string(text) = element {
                    result.append(text)
                } else {
                    log.warning(domain + ".type.mismatch", "Expected a string, found \(Self.describe(element)).", at: arrayPointer.appending(index))
                }
            }
            return result
        case let .string(text):
            mismatch(key, expected: "an array of strings", found: value, log: &log)
            return [text]
        default:
            mismatch(key, expected: "an array of strings", found: value, log: &log)
            return nil
        }
    }

    /// An array of integers; other elements are skipped.
    func ints(_ key: String, log: inout IssueLog) -> [Int]? {
        guard let value = raw(key) else { return nil }
        guard case let .array(elements) = value else {
            mismatch(key, expected: "an array of integers", found: value, log: &log)
            return nil
        }
        return elements.compactMap { element in
            switch element {
            case let .int(number): Int(exactly: number)
            case let .double(number) where number.isFinite && number == number.rounded() && abs(number) < 9e15: Int(number)
            default: nil
            }
        }
    }

    // MARK: Reporting

    func mismatch(_ key: String, expected: String, found value: JSONValue, log: inout IssueLog) {
        log.warning(domain + ".type.mismatch", "`\(key)` should be \(expected), found \(Self.describe(value)).", at: pointer.appending(key))
    }

    static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "a boolean"
        case .int, .double: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }
}
