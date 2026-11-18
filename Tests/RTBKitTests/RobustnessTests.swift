import Foundation
import Testing
@testable import RTBKit

/// SplitMix64: a tiny deterministic generator, so a failing fuzz case reproduces from its seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Malformed, mutated and hostile input never traps: the parsers report issues, and every candidate they return can be
/// planned for every lifecycle event and expanded.
@Suite("Robustness")
struct RobustnessTests {
    static let events: [AdLifecycleEvent] = [
        .won, .rendered, .viewable(.mrc50), .viewable(.mrc100), .viewable(.video50), .click(assetID: nil), .click(assetID: 1),
        .click(assetID: -1), .closed, .loss(reason: 102), .video(.start, adIndex: 0), .videoClick(adIndex: 3),
        .error(.noSupportedMedia, adIndex: nil),
    ]

    /// Values that stress type coercion, numbers, macros and encodings.
    static let hostileValues: [JSONValue] = [
        .null, .bool(true), .int(0), .int(-1), .int(Int64.max), .int(Int64.min), .double(1e308), .double(-1e308), .double(5e-324),
        .double(0.1), .string(""), .string("   "), .string("${AUCTION_PRICE}${AUCTION_PRICE:B64}[TIMESTAMP]%24%7BAUCTION_PRICE%7D"),
        .string("<VAST version=\"4.0\"><Ad></VAST>"), .string("{\"native\":{\"assets\":7}}"), .string("http://"), .string("data:,"),
        .string("\u{0}\u{FEFF}🧪\u{202E}"), .string(String(repeating: "x", count: 5000)), .array([]), .array([.null, .int(1), .string("a")]),
        .object([:]), .object(["native": .object(["assets": .array([.object(["id": .int(1)])])])]),
    ]

    /// Parses, then plans and expands everything that came out. Returns the number of candidates exercised.
    @discardableResult
    static func exercise(_ response: String, request: String?) -> Int {
        let input = InputParser.parse(response, request: request)
        let device = TrackingFixtures.phone
        for candidate in input.candidates {
            var native: NativeAd?
            if case let .native(json) = candidate.markup {
                let hints = input.request?.impressions.first { $0.id == candidate.impID }?.nativeHints
                native = NativeParser.parse(json, hints: hints).ad
            }
            let context = MacroContext.simulatorDefaults(candidate: candidate, request: input.request, device: device,
                                                         responseID: input.responseID, responseBidID: input.bidResponseID)
            for event in events {
                _ = TrackingPlan.requests(for: event, candidate: candidate, native: native, vast: ResolvedVAST(), context: context)
            }
            if case let .html(markup) = candidate.markup { _ = MacroExpander.expandMarkup(markup, context: context) }
        }
        return input.candidates.count
    }

    // MARK: Structural mutation

    /// Every path to a value in `value` (object keys and array indices).
    static func paths(in value: JSONValue, prefix: [PathStep] = [], into result: inout [[PathStep]]) {
        result.append(prefix)
        switch value {
        case let .object(members):
            for key in members.keys.sorted() { if let member = members[key] { paths(in: member, prefix: prefix + [.key(key)], into: &result) } }
        case let .array(elements):
            for (index, element) in elements.enumerated() { paths(in: element, prefix: prefix + [.index(index)], into: &result) }
        default:
            break
        }
    }

    enum PathStep {
        case key(String)
        case index(Int)
    }

    /// `value` with the node at `path` replaced (or removed when `replacement` is nil).
    static func replacing(_ value: JSONValue, at path: ArraySlice<PathStep>, with replacement: JSONValue?) -> JSONValue {
        guard let step = path.first else { return replacement ?? .null }
        switch (value, step) {
        case (var .object(members), let .key(key)):
            if path.count == 1, replacement == nil {
                members.removeValue(forKey: key)
            } else if let member = members[key] {
                members[key] = replacing(member, at: path.dropFirst(), with: replacement)
            }
            return .object(members)
        case (var .array(elements), let .index(index)) where elements.indices.contains(index):
            if path.count == 1, replacement == nil {
                elements.remove(at: index)
            } else {
                elements[index] = replacing(elements[index], at: path.dropFirst(), with: replacement)
            }
            return .array(elements)
        default:
            return value
        }
    }

    @Test(arguments: SampleLibrary.all.map(\.id))
    func structurallyMutatedSamplesNeverTrap(id: String) throws {
        let sample = try #require(SampleLibrary.sample(id: id))
        let root = try JSONValue.parse(sample.response)
        var allPaths: [[PathStep]] = []
        Self.paths(in: root, into: &allPaths)
        var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: id.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }))
        for _ in 0..<150 {
            var mutated = root
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                guard let path = allPaths.randomElement(using: &generator), !path.isEmpty else { continue }
                let replacement = Bool.random(using: &generator) ? Self.hostileValues.randomElement(using: &generator) : nil
                mutated = Self.replacing(mutated, at: path[...], with: replacement)
            }
            Self.exercise(mutated.serialized(), request: Bool.random(using: &generator) ? sample.request : nil)
        }
    }

    // MARK: Byte-level mutation

    @Test(arguments: SampleLibrary.all.map(\.id))
    func truncatedAndCorruptedTextNeverTraps(id: String) throws {
        let sample = try #require(SampleLibrary.sample(id: id))
        let bytes = Array(sample.response.utf8)
        var generator = SeededGenerator(seed: UInt64(bytes.count))
        let alphabet = Array(#"{}[]":,\0123456789.-+eE truefalsnul${}<>/%"#.utf8)
        for _ in 0..<100 {
            var mutated = bytes
            switch Int.random(in: 0..<3, using: &generator) {
            case 0:
                mutated = Array(mutated.prefix(Int.random(in: 0...mutated.count, using: &generator)))
            case 1:
                for _ in 0..<Int.random(in: 1...8, using: &generator) where !mutated.isEmpty {
                    mutated[Int.random(in: 0..<mutated.count, using: &generator)] = alphabet.randomElement(using: &generator) ?? 0
                }
            default:
                if !mutated.isEmpty { mutated.remove(at: Int.random(in: 0..<mutated.count, using: &generator)) }
            }
            Self.exercise(String(decoding: mutated, as: UTF8.self), request: sample.request)
        }
    }

    // MARK: Pathological input

    @Test func deepNestingIsRejectedWithoutTrapping() {
        let depth = 100_000
        let arrays = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        guard case .invalid = InputParser.parse(arrays).kind else { Issue.record("deep arrays"); return }
        let objects = String(repeating: #"{"native":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        guard case .invalid = InputParser.parse(objects).kind else { Issue.record("deep objects"); return }
        #expect(NativeParser.parse(objects).ad == nil)
        #expect(InputParser.parse(#"{"id":"r","seatbid":[]}"#, request: arrays).request == nil)
    }

    /// JSONSerialization overflows a 512 KB thread stack (Swift concurrency, test threads) on objects nested ~500 deep, so
    /// nesting is checked before it parses: up to 128 containers are accepted, deeper documents are rejected.
    @Test func nestingDepthIsCheckedBeforeFoundationParses() throws {
        func nested(_ depth: Int) -> String { String(repeating: #"{"a":["#, count: depth) + "1" + String(repeating: "]}", count: depth) }
        _ = try JSONValue.parse(nested(64))
        #expect(throws: JSONValue.ParseError.self) { try JSONValue.parse(nested(65)) }
        _ = try JSONValue.parse(String(repeating: "[", count: 128) + String(repeating: "]", count: 128))
        #expect(throws: JSONValue.ParseError.self) { try JSONValue.parse(String(repeating: "[", count: 129) + String(repeating: "]", count: 129)) }
        // Brackets inside strings do not count, including after an escaped quote and before an escaped backslash.
        let brackets = String(repeating: "{[", count: 300)
        let value = try JSONValue.parse(#"{"a":"\""# + brackets + #"\\","b":[1]}"#)
        #expect(value["a"] == .string("\"" + brackets + "\\"))
        #expect(value["b"] == [1])
    }

    @Test func extremeNumbersNeverTrap() {
        for price in ["1e400", "-1e400", "1e308", "-0", "123456789012345678901234567890", "5e-324"] {
            let json = #"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":"# + price + #","w":1e30,"h":-1e30,"exp":1e300,"mtype":1e19,"adm":"<p>${AUCTION_PRICE}</p>","nurl":"https://t.example/w?p=${AUCTION_PRICE}&m=${AUCTION_MBR}"}]}]}"#
            Self.exercise(json, request: #"{"id":"r","imp":[{"id":"1","banner":{"w":1e30,"h":99999999999999999999},"qty":{"multiplier":1e400}}],"device":{"geo":{"lat":1e400,"lon":-1e400},"lmt":1e30}}"#)
        }
    }

    @Test func hugeInputStaysLinear() {
        let bids = (0..<2000).map { #"{"id":"b\#($0)","impid":"1","price":1,"adm":"<p>${AUCTION_PRICE}</p>"}"# }.joined(separator: ",")
        #expect(Self.exercise(#"{"id":"r","seatbid":[{"bid":["# + bids + "]}]}", request: nil) == 2000)
    }
}
