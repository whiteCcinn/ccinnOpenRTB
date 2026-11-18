import Foundation
import Testing
@testable import RTBKit

@Suite("SampleLibrary")
struct SampleLibraryTests {
    enum MarkupKind: Equatable {
        case html, image, native, vastXML, none
    }

    struct Shape {
        var kind: InputKind
        var format: AdFormat?
        var markup: MarkupKind?
    }

    /// Every built-in sample, what it must parse as, and its first bid's format and markup.
    static let shapes: [String: Shape] = [
        "ortb25-banner-html": Shape(kind: .bidResponse(.v2("2.5")), format: .banner, markup: .html),
        "ortb26-mraid-interstitial": Shape(kind: .bidResponse(.v2("2.6")), format: .banner, markup: .html),
        "ortb25-nurl-markup": Shape(kind: .bidResponse(.v2("2.5")), format: .banner, markup: MarkupKind.none),
        "ortb25-native10-wrapped": Shape(kind: .bidResponse(.v2("2.5")), format: .native, markup: .native),
        "ortb26-native12-eventtrackers": Shape(kind: .bidResponse(.v2("2.6")), format: .native, markup: .native),
        "ortb26-vast20-inline": Shape(kind: .bidResponse(.v2("2.6")), format: .video, markup: .vastXML),
        "ortb26-vast30-skippable": Shape(kind: .bidResponse(.v2("2.6")), format: .video, markup: .vastXML),
        "ortb26-vast40-inline": Shape(kind: .bidResponse(.v2("2.6")), format: .video, markup: .vastXML),
        "ortb26-vast41-ctv-pod": Shape(kind: .bidResponse(.v2("2.6")), format: .video, markup: .vastXML),
        "ortb26-vast42-verification": Shape(kind: .bidResponse(.v2("2.6")), format: .video, markup: .vastXML),
        "ortb26-vast30-wrapper-chain": Shape(kind: .bidResponse(.v2("2.6")), format: .video, markup: .vastXML),
        "ortb26-vast30-vpaid-only": Shape(kind: .bidResponse(.v2("2.6")), format: .video, markup: .vastXML),
        "ortb26-audio-vast40": Shape(kind: .bidResponse(.v2("2.6")), format: .audio, markup: .vastXML),
        "ortb30-display-banner": Shape(kind: .bidResponse(.v3("3.0")), format: .banner, markup: .image),
        "ortb30-display-native": Shape(kind: .bidResponse(.v3("3.0")), format: .native, markup: .native),
        "ortb30-display-curl": Shape(kind: .bidResponse(.v3("3.0")), format: .banner, markup: MarkupKind.none),
        "ortb30-video": Shape(kind: .bidResponse(.v3("3.0")), format: .video, markup: .vastXML),
        "ortb26-no-bid": Shape(kind: .bidResponse(.v2("2.x")), format: nil, markup: nil),
    ]

    static func markupKind(_ markup: AdMarkup) -> MarkupKind? {
        switch markup {
        case .html: .html
        case .image: .image
        case .native: .native
        case .vast(.xml): .vastXML
        case .vast(.url): nil
        case .none: MarkupKind.none
        }
    }

    static func sample(_ id: String) throws -> Sample {
        try #require(SampleLibrary.sample(id: id), "no sample \(id)")
    }

    @Test func everyListedSampleIsCoveredAndIDsAndTitlesAreUnique() {
        let ids = SampleLibrary.all.map(\.id)
        #expect(Set(ids) == Set(Self.shapes.keys))
        #expect(Set(ids).count == ids.count)
        #expect(Set(SampleLibrary.all.map(\.title)).count == ids.count)
        #expect(SampleLibrary.all.allSatisfy { !$0.group.isEmpty && !$0.title.isEmpty })
        #expect(SampleLibrary.sample(id: "nope") == nil)
    }

    @Test(arguments: SampleLibrary.all.map(\.id))
    func parsesAsDeclaredWithoutErrorsOrWarnings(id: String) throws {
        let sample = try Self.sample(id)
        let shape = try #require(Self.shapes[id])
        let input = InputParser.parse(sample.response, request: sample.request)
        #expect(input.kind == shape.kind)
        #expect(!input.issues.contains { $0.severity != .info }, "\(input.issues.filter { $0.severity != .info })")
        if sample.request != nil { #expect(input.request != nil) }
        guard let format = shape.format else {
            #expect(input.candidates.isEmpty)
            return
        }
        let bid = try #require(input.candidates.first)
        #expect(bid.format == format)
        #expect(Self.markupKind(bid.markup) == shape.markup)
        #expect(bid.price > 0)
    }

    @Test func videoSamplesWrapTheVASTSamplesConstants() throws {
        let embedded: [String: String] = [
            "ortb26-vast20-inline": VASTSamples.inline20, "ortb26-vast30-skippable": VASTSamples.inline30Skippable,
            "ortb26-vast40-inline": VASTSamples.inline40, "ortb26-vast41-ctv-pod": VASTSamples.pod41,
            "ortb26-vast42-verification": VASTSamples.inline42Verification, "ortb26-vast30-wrapper-chain": VASTSamples.wrapperChain30,
            "ortb26-vast30-vpaid-only": VASTSamples.vpaidOnly, "ortb26-audio-vast40": VASTSamples.audio40, "ortb30-video": VASTSamples.inline40,
        ]
        for (id, xml) in embedded {
            let sample = try Self.sample(id)
            #expect(InputParser.parse(sample.response, request: sample.request).candidates.first?.markup == .vast(.xml(xml)), "\(id)")
        }
    }

    @Test func native10TypesComeFromTheMatchingRequest() throws {
        let sample = try Self.sample("ortb25-native10-wrapped")
        let input = InputParser.parse(sample.response, request: sample.request)
        guard case let .native(json)? = input.candidates.first?.markup else { Issue.record("native markup"); return }
        let hints = try #require(input.request?.impressions.first?.nativeHints)
        let native = try #require(NativeParser.parse(json, hints: hints).ad)
        #expect(native.wrapped)
        #expect(native.version == "1")
        #expect(native.assets.filter { $0.typeSource == .request }.count == 4)
        #expect(native.impressionTrackers.count == 1)
        #expect(native.jsTracker != nil)
    }

    @Test func native12HasAnImagePixelImpressionAndAJavaScriptViewabilityTracker() throws {
        let sample = try Self.sample("ortb26-native12-eventtrackers")
        let input = InputParser.parse(sample.response, request: sample.request)
        let bid = try #require(input.candidates.first)
        guard case let .native(json) = bid.markup else { Issue.record("native markup"); return }
        let hints = input.request?.impressions.first?.nativeHints
        let parsed = NativeParser.parse(json, hints: hints)
        let native = try #require(parsed.ad)
        #expect(!native.wrapped)
        #expect(native.eventTrackers.map { [$0.event, $0.method] } == [[1, 1], [2, 2]])
        #expect(native.privacyURL != nil)

        // End to end: the simulator's context, then the plan.
        let context = MacroContext.simulatorDefaults(candidate: bid, request: input.request, device: TrackingFixtures.phone,
                                                     responseID: input.responseID, responseBidID: input.bidResponseID)
        let impression = TrackingPlan.requests(for: .rendered, candidate: bid, native: native, vast: nil, context: context)
        #expect(impression.map(\.category) == [.billing, .impression])
        #expect(impression.allSatisfy { $0.unknownMacros.isEmpty && !$0.url.contains("${") })
        let viewable = TrackingPlan.requests(for: .viewable(.mrc50), candidate: bid, native: native, vast: nil, context: context)
        #expect(viewable.map(\.isScript) == [true])
    }

    @Test func markupByReferenceSamples() throws {
        let nurl = try Self.sample("ortb25-nurl-markup")
        let input = InputParser.parse(nurl.response, request: nurl.request)
        let bid = try #require(input.candidates.first)
        #expect(input.issues.contains { $0.code == "openrtb.bid.markup.winnotice" })
        let winURL = try #require(bid.winURL)
        #expect(Self.decodedDataURL(winURL)?.contains("<") == true)

        let curl = try Self.sample("ortb30-display-curl")
        let curlBid = try #require(InputParser.parse(curl.response, request: curl.request).candidates.first)
        #expect(curlBid.markupURL.flatMap(Self.decodedDataURL)?.contains("<") == true)
    }

    @Test func openRTB3BannerHasLoadedImpressionAndViewabilityEventsAndABuyerMacro() throws {
        let sample = try Self.sample("ortb30-display-banner")
        let input = InputParser.parse(sample.response, request: sample.request)
        let bid = try #require(input.candidates.first)
        #expect(bid.adcomEvents.map(\.type) == [1, 2, 3])
        #expect(!bid.customMacros.isEmpty)
        let context = MacroContext.simulatorDefaults(candidate: bid, request: input.request, device: TrackingFixtures.phone,
                                                     responseID: input.responseID, responseBidID: input.bidResponseID)
        let click = TrackingPlan.requests(for: .click(assetID: nil), candidate: bid, native: nil, vast: nil, context: context)
        #expect(click.map(\.category) == [.click, .navigation])
        #expect(click.allSatisfy { $0.unknownMacros.isEmpty && !$0.url.contains("${") })
    }

    @Test func noBidNamesTheReason() throws {
        let input = InputParser.parse(try Self.sample("ortb26-no-bid").response)
        #expect(input.noBidReason == 2)
    }

    /// Nothing a sample loads reaches a real host: trackers and landing pages are on reserved `.example` domains (RFC 2606),
    /// over HTTPS, and media are `ccinn-sample://` URLs the app serves locally.
    @Test(arguments: SampleLibrary.all.map(\.id))
    func everyURLIsOfflineAndSecure(id: String) throws {
        let sample = try Self.sample(id)
        let text = sample.response + "\n" + (sample.request ?? "")
        let withoutNamespaces = text.replacingOccurrences(of: #"xmlns(:[A-Za-z]+)?=\\?"[^"\\]*\\?""#, with: "", options: .regularExpression)
        let pattern = try NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>\\)\]]+"#)
        let range = NSRange(withoutNamespaces.startIndex..., in: withoutNamespaces)
        for match in pattern.matches(in: withoutNamespaces, range: range) {
            guard let matchRange = Range(match.range, in: withoutNamespaces) else { continue }
            let url = String(withoutNamespaces[matchRange])
            if url.hasPrefix("ccinn-sample://") { continue }
            #expect(url.hasPrefix("https://"), "\(id): \(url)")
            let host = URLComponents(string: url.replacingOccurrences(of: "${", with: "").replacingOccurrences(of: "}", with: ""))?.host ?? ""
            #expect(host == "example" || host.hasSuffix(".example"), "\(id): \(url)")
        }
    }

    static func decodedDataURL(_ url: String) -> String? {
        guard let comma = url.firstIndex(of: ","), url.hasPrefix("data:"), url[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...])).map { String(decoding: $0, as: UTF8.self) }
    }
}
