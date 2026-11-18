import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// AdTech review, the rule by origin, end to end on the real kit: OpenRTB `${…}` is substituted only where the exchange
/// does it — the bid response (inline adm, notice URLs); VAST `[…]` only by the player, in VAST URLs (tracking and
/// request URIs alike); a document fetched after the win, from a wrapper or from a pasted tag keeps `${…}` as written,
/// with a warning.
@MainActor
@Suite("Acceptance: macros by origin", .serialized)
struct MacroOriginAcceptanceTests {
    private static let cacheBuster = #"[0-9]{8}"#

    private static func response(_ bid: String) -> String {
        """
        {"id": "req-1", "cur": "USD", "seatbid": [{"seat": "dsp", "bid": [{"id": "bid-1", "impid": "1", "price": 1.5, "w": 640, "h": 360, \(bid)}]}]}
        """
    }

    private static func inline(impression: String) -> String {
        """
        <VAST version="4.1"><Ad id="i"><InLine><AdSystem>t</AdSystem><AdTitle>t</AdTitle>
          <Impression><![CDATA[\(impression)]]></Impression>
          <Creatives><Creative><Linear><Duration>00:00:15</Duration><MediaFiles>
            <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile>
          </MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>
        """
    }

    private func render(_ sample: Sample, transport: CountingTransport) async throws -> AcceptanceSession {
        let harness = AcceptanceSession(transport: transport)
        try await harness.render(sample)
        #expect(harness.session.phase == .ready, "\(harness.session.phase)")
        return harness
    }

    private func firedImpression(_ harness: AcceptanceSession) async throws -> NetworkEntry {
        harness.session.rendererHost.report(.video(.creativeView, adIndex: 0))
        await harness.monitor.waitUntilIdle()
        return try #require(harness.monitor.liveEntries.first { $0.category == .impression }, "\(harness.monitor.liveEntries.map(\.category))")
    }

    /// Inline HTML adm: `${…}` substituted by the exchange; `[…]` is not a macro in HTML and stays.
    @Test func inlineHTML() async throws {
        let adm = JSONValue.string(#"<img src="https://t.example/px?p=${AUCTION_PRICE}&cb=[CACHEBUSTING]">"#).serialized()
        let harness = try await render(Sample(id: "m", title: "m", group: "t", response: Self.response(#""mtype": 1, "adm": \#(adm)"#)),
                                       transport: CountingTransport())
        #expect(harness.session.renderRequest?.candidate.markup == .html(#"<img src="https://t.example/px?p=1.5&cb=[CACHEBUSTING]">"#))
        #expect(!harness.session.renderIssues.contains { $0.code.contains("unsubstituted") })
    }

    /// OpenRTB 3.0 `display.native` is inline markup of the bid response too: the exchange's `${OPENRTB_*}` are in before
    /// the Native ad is parsed (AdTech review 2, origin "adm").
    @Test func inlineNative30() async throws {
        let response = #"""
        {"openrtb": {"ver": "3.0", "response": {"id": "req-1", "seatbid": [{"seat": "dsp", "bid": [{"id": "bid-1", "item": "1", "price": 1.5,
          "media": {"ad": {"id": "ad-1", "display": {"w": 320, "h": 250, "native": {"asset": [{"id": 1, "title": {"text": "T"}}],
            "link": {"url": "https://adv.example/?p=${OPENRTB_PRICE}"}, "imptrackers": ["https://t.example/imp?p=${OPENRTB_PRICE}"]}}}}}]}]}}}
        """#
        let harness = try await render(Sample(id: "m", title: "m", group: "t", response: response), transport: CountingTransport())
        let native = try #require(harness.session.prepared?.native)
        #expect(native.link.url == "https://adv.example/?p=1.5", "\(native.link.url)")
        #expect(native.impressionTrackers == ["https://t.example/imp?p=1.5"], "\(native.impressionTrackers)")
    }

    /// AdCOM `display.curl` HTML: fetched after the win, used as written, with a warning.
    @Test func curlHTML() async throws {
        let transport = CountingTransport()
        transport.respond("https://cdn.example/creative.html", body: #"<img src="https://t.example/px?p=${AUCTION_PRICE}">"#)
        let response = """
        {"openrtb": {"ver": "3.0", "response": {"id": "req-1", "seatbid": [{"seat": "dsp", "bid": [{"id": "bid-1", "item": "1", "price": 1.5,
          "media": {"ad": {"id": "ad-1", "display": {"w": 320, "h": 50, "curl": "https://cdn.example/creative.html"}}}}]}]}}}
        """
        let harness = try await render(Sample(id: "m", title: "m", group: "t", response: response), transport: transport)
        #expect(harness.session.renderRequest?.candidate.markup == .html(#"<img src="https://t.example/px?p=${AUCTION_PRICE}">"#))
        #expect(harness.session.renderIssues.contains { $0.code == "openrtb.macro.unsubstituted" && $0.message.contains("${AUCTION_PRICE}") })
    }

    /// Inline VAST adm: the exchange's `${…}` is in before parsing; the player's `[…]` stays until the tracker fires.
    @Test func inlineVAST() async throws {
        let adm = JSONValue.string(Self.inline(impression: "https://t.example/imp?p=${AUCTION_PRICE}&cb=[CACHEBUSTING]")).serialized()
        let harness = try await render(Sample(id: "m", title: "m", group: "t", response: Self.response(#""mtype": 2, "adm": \#(adm)"#)),
                                       transport: CountingTransport())
        let impression = try await firedImpression(harness)
        #expect(impression.url.range(of: #"^https://t\.example/imp\?p=1\.5&cb="# + Self.cacheBuster + "$", options: .regularExpression) != nil,
                "\(impression.url)")
        #expect(!harness.session.renderIssues.contains { $0.code.contains("unsubstituted") })
    }

    /// A wrapper hop: the request URI's `[…]` is expanded by the player when it fetches (VAST 4.1 §6.1); the served
    /// document's `${…}` stays literal when fired, with the resolver's warning.
    @Test func wrapperHop() async throws {
        let transport = CountingTransport()
        transport.respondByPrefix("https://ad.example/inline.xml", body: Self.inline(impression: "https://t.example/imp?p=${AUCTION_PRICE}&cb=[CACHEBUSTING]"))
        let wrapper = """
        <VAST version="4.1"><Ad id="w"><Wrapper><AdSystem>t</AdSystem>
          <VASTAdTagURI><![CDATA[https://ad.example/inline.xml?cb=[CACHEBUSTING]&p=${AUCTION_PRICE}]]></VASTAdTagURI>
          <Impression><![CDATA[https://t.example/wrapper-imp]]></Impression></Wrapper></Ad></VAST>
        """
        let adm = JSONValue.string(wrapper).serialized()
        let harness = try await render(Sample(id: "m", title: "m", group: "t", response: Self.response(#""mtype": 2, "adm": \#(adm)"#)),
                                       transport: transport)
        let fetched = try #require(transport.requests.first { $0.url.absoluteString.hasPrefix("https://ad.example/inline.xml") })
        #expect(fetched.url.absoluteString.range(of: #"\?cb="# + Self.cacheBuster + #"&p=1\.5$"#, options: .regularExpression) != nil,
                "the player expands [CACHEBUSTING] in the request URI; the exchange already put the price in the adm: \(fetched.url)")
        let hop = try #require(harness.monitor.liveEntries.first { $0.url == fetched.url.absoluteString })
        #expect(hop.template == "https://ad.example/inline.xml?cb=[CACHEBUSTING]&p=1.5", "the URI as written next to the URL sent")
        #expect(hop.trigger == MonitorVASTFetcher.wrapperTrigger)
        let impressions = harness.monitor.liveEntries.isEmpty ? [] : try await { () async throws -> [NetworkEntry] in
            _ = try await firedImpression(harness)
            return harness.monitor.liveEntries.filter { $0.category == .impression }
        }()
        let served = try #require(impressions.first { $0.url.hasPrefix("https://t.example/imp") })
        #expect(served.url.range(of: #"^https://t\.example/imp\?p=\$\{AUCTION_PRICE\}&cb="# + Self.cacheBuster + "$", options: .regularExpression) != nil,
                "\(served.url)")
        #expect(harness.session.renderIssues.contains { $0.code == "vast.macro.openrtb.unsubstituted" })
    }

    /// AdTech review 6 on the real kit: `[ASSETURI]` is the chosen media file, `[BREAKPOSITION]` 4 (standalone) on a phone
    /// and 1 (pre-roll) in the CTV instream break, `[ADCOUNT]` the ads that will play.
    @Test(arguments: [("iphone-17-pro", "4"), ("apple-tv-4k", "1")])
    func playbackMacros(deviceID: String, breakPosition: String) async throws {
        let vast = Self.inline(impression: "https://t.example/imp").replacingOccurrences(of: "<Duration>00:00:15</Duration>", with: """
        <Duration>00:00:15</Duration><TrackingEvents><Tracking event="start"><![CDATA[https://t.example/start?a=[ASSETURI]&bp=[BREAKPOSITION]&n=[ADCOUNT]]]></Tracking></TrackingEvents>
        """)
        let adm = JSONValue.string(vast).serialized()
        let harness = AcceptanceSession(transport: CountingTransport())
        harness.session.device = try #require(DeviceCatalog.device(id: deviceID))
        await harness.session.load(Sample(id: "m", title: "m", group: "t", response: Self.response(#""mtype": 2, "adm": \#(adm)"#)), render: true)
        await harness.waitUntilSettled()
        #expect(harness.session.phase == .ready, "\(harness.session.phase)")
        harness.session.rendererHost.playbackChanged(PlaybackStatus(adIndex: 0, playhead: 0, duration: 15, isPlaying: true, isMuted: true,
                                                                   assetURI: "ccinn-sample://media/sample-15s.mp4"))
        harness.session.rendererHost.report(.video(.start, adIndex: 0))
        await harness.monitor.waitUntilIdle()
        let start = try #require(harness.monitor.liveEntries.first { $0.url.hasPrefix("https://t.example/start") })
        #expect(start.url == "https://t.example/start?a=ccinn-sample%3A%2F%2Fmedia%2Fsample-15s.mp4&bp=\(breakPosition)&n=1", "\(start.url)")
    }

    /// A pasted VAST tag URL: the document is served, never substituted by an exchange.
    @Test func pastedTag() async throws {
        let transport = CountingTransport()
        transport.respondByPrefix("https://ad.example/tag.xml", body: Self.inline(impression: "https://t.example/imp?p=${AUCTION_PRICE}"))
        let harness = try await render(Sample(id: "m", title: "m", group: "t", response: "https://ad.example/tag.xml?cb=[CACHEBUSTING]"),
                                       transport: transport)
        let fetched = try #require(transport.requests.first)
        #expect(fetched.url.absoluteString.range(of: #"cb="# + Self.cacheBuster + "$", options: .regularExpression) != nil, "\(fetched.url)")
        let tag = try #require(harness.monitor.liveEntries.first { $0.url == fetched.url.absoluteString })
        #expect(tag.template == "https://ad.example/tag.xml?cb=[CACHEBUSTING]")
        #expect(tag.trigger == MonitorVASTFetcher.tagTrigger, "the pasted tag is the VAST tag, not a wrapper")
        let impression = try await firedImpression(harness)
        #expect(impression.url == "https://t.example/imp?p=${AUCTION_PRICE}")
        #expect(harness.session.renderIssues.contains { $0.code == "vast.macro.openrtb.unsubstituted" })
    }
}
