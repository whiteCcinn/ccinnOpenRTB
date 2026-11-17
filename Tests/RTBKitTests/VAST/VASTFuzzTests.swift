import Foundation
import Testing
@testable import RTBKit

/// Mutation fuzzing: no input may crash, hang or produce an inconsistent resolution.
@Suite("VAST fuzz")
struct VASTFuzzTests {
    /// SplitMix64: deterministic, so a failure reproduces from its seed.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    private static let fragments = ["<", ">", "&", "&amp;", "]]>", "<![CDATA[", "<Ad>", "</Ad>", "<Wrapper>", "<InLine>", "sequence=\"-1\"",
                                    "offset=\"200%\"", "skipoffset=\"99:99:99\"", "<Tracking event=\"progress\" offset=\"00:00:01\">x</Tracking>",
                                    "<VASTAdTagURI>data:application/xml,%3CVAST%3E</VASTAdTagURI>", "\u{0}", "\u{FEFF}", "é", "<!DOCTYPE x>",
                                    "<Duration>00:00:</Duration>", "<MediaFile>", "version=\"9\""]

    private static func mutate(_ text: String, using generator: inout SeededGenerator) -> String {
        var characters = Array(text)
        for _ in 0..<Int.random(in: 1...4, using: &generator) {
            guard !characters.isEmpty else { break }
            let position = Int.random(in: 0..<characters.count, using: &generator)
            switch Int.random(in: 0..<5, using: &generator) {
            case 0:
                let length = Int.random(in: 1...min(40, characters.count - position), using: &generator)
                characters.removeSubrange(position..<(position + length))
            case 1:
                let length = Int.random(in: 1...min(80, characters.count - position), using: &generator)
                characters.insert(contentsOf: characters[position..<(position + length)], at: position)
            case 2:
                characters.insert(contentsOf: Array(fragments.randomElement(using: &generator) ?? "<"), at: position)
            case 3:
                characters = Array(characters.prefix(position))
            default:
                characters[position] = Character(UnicodeScalar(UInt8.random(in: 32...126, using: &generator)))
            }
        }
        return String(characters)
    }

    @Test(arguments: VASTSamples.all.map(\.id))
    func mutatedSamplesNeverCrash(_ id: String) async throws {
        let sample = try #require(VASTSamples.all.first { $0.id == id })
        var generator = SeededGenerator(state: UInt64(truncatingIfNeeded: id.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }))
        let resolver = VASTResolver(fetcher: FakeVASTFetcher())
        for _ in 0..<150 {
            let xml = Self.mutate(sample.xml, using: &generator)
            _ = VASTParser.parse(xml)
            let vast = await resolver.resolve(.xml(xml))
            Self.checkInvariants(vast)
            for (index, _) in vast.ads.enumerated() {
                for event: AdLifecycleEvent in [.video(.creativeView, adIndex: index), .video(.progress(.percent(25)), adIndex: index),
                                                .videoClick(adIndex: index), .companionClick(adIndex: index, companionIndex: 0),
                                                .videoViewability(.viewable, adIndex: index), .error(.linearError, adIndex: index)] {
                    _ = VASTTrackingPlan.requests(for: event, vast: vast, candidate: nil, context: MacroContext(), source: "fuzz")
                }
                _ = VASTMediaSelector.choose(vast.ads[index].inline.playedLinear?.mediaFiles ?? [], playerWidth: 1280, playerHeight: 720)
            }
            _ = VASTTrackingPlan.requests(for: .error(.undefinedError, adIndex: nil), vast: vast, candidate: nil, context: MacroContext(), source: "f")
            _ = VASTTrackingPlan.resolutionRequests(vast: vast, context: MacroContext(), source: "fuzz")
        }
    }

    @Test func randomBytesNeverCrash() {
        var generator = SeededGenerator(state: 42)
        for _ in 0..<300 {
            let length = Int.random(in: 0...400, using: &generator)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = VASTParser.parse("<VAST version=\"4.2\">" + String(decoding: bytes, as: UTF8.self))
            _ = VASTParser.parse(String(decoding: bytes, as: UTF8.self))
        }
    }

    @Test func manyAdsAndTrackersStayFast() async {
        let ads = (1...300).map { (index: Int) in VASTFixture.inlineAd(id: "a\(index)", sequence: index, name: "ad\(index)") }
        let started = Date()
        let vast = await VASTResolver(fetcher: FakeVASTFetcher()).resolve(.xml(VASTFixture.document(ads: ads)))
        #expect(vast.ads.count == 300)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// Every resolution is either playable or failed, never both; every origin and parent points into the chain.
    private static func checkInvariants(_ vast: ResolvedVAST, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(vast.ads.isEmpty == (vast.failure != nil), sourceLocation: sourceLocation)
        if vast.failure == nil { #expect(vast.failureErrorURLs.isEmpty, sourceLocation: sourceLocation) }
        #expect(!vast.chain.isEmpty, sourceLocation: sourceLocation)
        let origins = vast.ads.flatMap(\.origin) + vast.adFailures.flatMap(\.origin) + vast.chain.compactMap(\.parent)
        for origin in origins {
            let ads = vast.chain.indices.contains(origin.hop) ? vast.chain[origin.hop].document?.ads ?? [] : []
            #expect(ads.indices.contains(origin.ad), sourceLocation: sourceLocation)
        }
        for ad in vast.ads {
            #expect(VASTLineage(origin: ad.origin, chain: vast.chain) != nil, sourceLocation: sourceLocation)
        }
    }
}
