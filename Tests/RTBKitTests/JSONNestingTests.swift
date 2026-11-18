import Foundation
import Testing
@testable import RTBKit

/// JSONSerialization recurses once per nesting level and overflows a 512 KB thread stack at roughly 500 levels, so
/// `JSONValue.parse` accepts at most 128 levels of arrays and objects. A deeper document gets an issue saying
/// "nested too deeply" (not "invalid JSON") at the JSON pointer of the first array or object past the limit, in every
/// document the simulator reads: the response, a Native `adm`, the bid request and its Native request string.
@Suite("JSON nesting limit")
struct JSONNestingTests {
    /// `levels` nested containers, objects and arrays alternating, the innermost holding `0`. Every level also holds a
    /// sibling before the nested value, so the pointer must take the right member name and element index: object
    /// members are `"x"` then `"a\/b~cé"` (escaped in the source: `/` and `~` need RFC 6901 escaping), and arrays hold
    /// a string full of brackets, a comma and an escaped quote before the nested element at index 1.
    static func nested(_ levels: Int) -> String {
        var opening = ""
        var closing: [String] = []
        for level in 0..<levels {
            if level.isMultiple(of: 2) {
                opening += #"{"x":1,"a\/b~cé":"#
                closing.append("}")
            } else {
                opening += #"["[,\"]{","#
                closing.append("]")
            }
        }
        return opening + "0" + closing.reversed().joined()
    }

    /// The reference tokens of `nested(_:)` down to (not including) container `level` (1-based).
    static func tokens(before level: Int) -> String {
        (1..<max(1, level)).map { $0 % 2 == 1 ? "/a~1b~0cé" : "/1" }.joined()
    }

    static func nestedTooDeeply(_ issue: ValidationIssue?) -> Bool {
        guard let issue else { return false }
        return issue.message.localizedCaseInsensitiveContains("nested too deeply") && !issue.message.localizedCaseInsensitiveContains("invalid json")
    }

    // MARK: JSONValue

    @Test func oneHundredTwentyEightLevelsParse() throws {
        var value = try JSONValue.parse(Self.nested(128))
        for level in 1..<128 {
            value = try #require(level % 2 == 1 ? value["a/b~cé"] : value[1], "level \(level)")
        }
        #expect(value == .array(["[,\"]{", 0]))
        #expect(JSONValue.maxNestingDepth == 128)
    }

    @Test func oneHundredTwentyNineLevelsAreRejectedWhereTheyStart() {
        #expect(throws: JSONValue.ParseError(reason: .nestedTooDeeply(pointer: Self.tokens(before: 129)))) {
            try JSONValue.parse(Self.nested(129))
        }
        #expect(throws: JSONValue.ParseError(reason: .nestedTooDeeply(pointer: String(repeating: "/0", count: 128)))) {
            try JSONValue.parse(String(repeating: "[", count: 129) + String(repeating: "]", count: 129))
        }
        let error = JSONValue.ParseError(reason: .nestedTooDeeply(pointer: "/a"))
        #expect(error.description.localizedCaseInsensitiveContains("nested too deeply"))
        #expect(error.description.contains("128"))
    }

    /// A raw NUL is never valid JSON (RFC 8259 §7) and, at the start of a document, makes Foundation guess UTF-16/32,
    /// where the byte scan would no longer see the brackets Foundation sees. It is rejected before either runs.
    @Test func aNULByteIsMalformed() {
        for json in ["\u{0}\u{0}\u{0}[1]", "[\"a\u{0}\"]", "[1]\u{0}"] {
            let error = #expect(throws: JSONValue.ParseError.self) { try JSONValue.parse(json) }
            guard case .malformed? = error?.reason else { Issue.record("\(String(describing: error))"); continue }
            #expect(error?.description.hasPrefix("Invalid JSON") == true)
        }
    }

    // MARK: Documents

    /// The response: the root, `seatbid`, `seatbid[0]`, `bid` and `bid[0]` are five levels, then `ext`.
    static func response(ext: String) -> String {
        #"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"<p>x</p>","ext":"# + ext + "}]}]}"
    }

    @Test func responseAtTheLimitParses() {
        let input = InputParser.parse(Self.response(ext: Self.nested(123)))
        guard case .bidResponse(.v2) = input.kind else { Issue.record("kind \(input.kind)"); return }
        #expect(input.candidates.count == 1)
        #expect(!input.issues.contains { $0.code.hasPrefix("input.json") })
    }

    @Test func responseNestedTooDeeply() throws {
        let input = InputParser.parse(Self.response(ext: Self.nested(124)))
        guard case let .invalid(reason) = input.kind else { Issue.record("kind \(input.kind)"); return }
        #expect(reason.localizedCaseInsensitiveContains("nested too deeply"))
        #expect(input.issues.count == 1)
        let issue = try #require(input.issues.first)
        #expect(issue.code == "input.json.depth")
        #expect(issue.severity == .error)
        #expect(issue.path == "/seatbid/0/bid/0/ext" + Self.tokens(before: 124))
        #expect(Self.nestedTooDeeply(issue))
    }

    /// Native `adm` is its own document (a JSON string): the root and `native` are two levels, then `ext`. Without
    /// `mtype` the `adm` is still recognised as Native JSON, so the depth is reported instead of an HTML banner.
    @Test(arguments: [nil, 4])
    func nativeMarkupNestedTooDeeply(mtype: Int?) throws {
        let native = #"{"native":{"ver":"1.2","link":{"url":"https://l.example/"},"assets":[],"ext":"# + Self.nested(127) + "}}"
        let bid = #"{"id":"b","impid":"1","price":1,"# + (mtype.map { #""mtype":\#($0),"# } ?? "") + #""adm":"# + JSONValue.string(native).serialized() + "}"
        let input = InputParser.parse(#"{"id":"r","seatbid":[{"bid":["# + bid + "]}]}")
        #expect(input.candidates.first?.format == .native)
        let issue = try #require(input.issues.first { $0.code == "native.json.depth" })
        #expect(issue.severity == .error)
        #expect(issue.path == "/seatbid/0/bid/0/adm/native/ext" + Self.tokens(before: 127))
        #expect(Self.nestedTooDeeply(issue))
        #expect(!input.issues.contains { $0.code == "openrtb.bid.markup.mismatch" })
    }

    /// `{"native": "{…}"}` (double-encoded): the inner string is a document of its own, reported under `/native`.
    @Test func doubleEncodedNativeNestedTooDeeply() throws {
        let inner = #"{"ext":"# + Self.nested(128) + "}"
        let issues = NativeParser.parse(#"{"native":"# + JSONValue.string(inner).serialized() + "}").issues
        let issue = try #require(issues.first { $0.code == "native.json.depth" })
        #expect(issue.path == "/native/ext" + Self.tokens(before: 128))
        #expect(Self.nestedTooDeeply(issue))
    }

    @Test func requestNestedTooDeeply() throws {
        let request = #"{"id":"r","imp":[{"id":"1","banner":{"w":1,"h":1}}],"ext":"# + Self.nested(128) + "}"
        let input = InputParser.parse(OpenRTBFixtures.spec25WinNotice, request: request)
        #expect(input.request == nil)
        guard case .bidResponse(.v2) = input.kind else { Issue.record("kind \(input.kind)"); return }
        let issue = try #require(input.issues.first { $0.code == "request.json.depth" })
        #expect(issue.severity == .warning)
        #expect(issue.path == "request:/ext" + Self.tokens(before: 128))
        #expect(Self.nestedTooDeeply(issue))
        #expect(!input.issues.contains { $0.code == "request.json.invalid" })
        // One level less is accepted.
        let accepted = #"{"id":"r","imp":[{"id":"1","banner":{"w":1,"h":1}}],"ext":"# + Self.nested(127) + "}"
        #expect(InputParser.parse(OpenRTBFixtures.spec25WinNotice, request: accepted).request?.impressions.count == 1)
    }

    /// `imp.native.request` is a JSON string: the root and `native` are two levels, then `ext`.
    @Test func nativeRequestNestedTooDeeply() throws {
        let nativeRequest = #"{"native":{"ver":"1.2","assets":[],"ext":"# + Self.nested(127) + "}}"
        let request = #"{"id":"r","imp":[{"id":"1","native":{"request":"# + JSONValue.string(nativeRequest).serialized() + "}}]}"
        let input = InputParser.parse(OpenRTBFixtures.spec25WinNotice, request: request)
        #expect(input.request?.impressions.first?.nativeHints == nil)
        let issue = try #require(input.issues.first { $0.code == "request.native.depth" })
        #expect(issue.severity == .warning)
        #expect(issue.path == "request:/imp/0/native/request/native/ext" + Self.tokens(before: 127))
        #expect(Self.nestedTooDeeply(issue))
    }
}
