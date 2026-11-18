import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// OpenRTB 2.6 §4.4 on the real kit: the exchange substitutes its `${…}` auction macros in the bid's inline `adm`
/// (HTML, Native JSON, VAST XML) before the device sees it; VAST `[…]` macros stay in the markup until the player fires
/// the tracker. Markup fetched after the win (nurl, `display.curl`) is used as delivered.
@MainActor
@Suite("Acceptance: the exchange's macros in inline markup", .serialized)
struct ExchangeMacroAcceptanceTests {
    private static func response(mtype: Int, adm: String) -> String {
        let escaped = JSONValue.string(adm).serialized()
        return """
        {"id": "req-1", "bidid": "resp-1", "cur": "USD", "seatbid": [{"seat": "dsp", "bid": [{"id": "bid-1", "impid": "1", "price": 1.5,
          "mtype": \(mtype), "w": 640, "h": 360, "burl": "https://t.example/bill?p=${AUCTION_PRICE}", "adm": \(escaped)}]}]}
        """
    }

    private func render(_ response: String) async throws -> AcceptanceSession {
        let harness = AcceptanceSession(transport: CountingTransport())
        try await harness.render(Sample(id: "test", title: "test", group: "test", response: response))
        #expect(harness.session.phase == .ready, "\(harness.session.phase)")
        return harness
    }

    @Test func vastAdmCarriesThePriceButKeepsCachebustingUntilTheTrackerFires() async throws {
        let vast = """
        <VAST version="3.0"><Ad id="a"><InLine><AdSystem>t</AdSystem><AdTitle>t</AdTitle>
          <Impression><![CDATA[https://t.example/imp?p=${AUCTION_PRICE}&cb=[CACHEBUSTING]]]></Impression>
          <Creatives><Creative><Linear><Duration>00:00:15</Duration>
            <TrackingEvents><Tracking event="start"><![CDATA[https://t.example/start?p=${AUCTION_PRICE}&ph=[ADPLAYHEAD]]]></Tracking></TrackingEvents>
            <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1280" height="720"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile></MediaFiles>
          </Linear></Creative></Creatives></InLine></Ad></VAST>
        """
        let harness = try await render(Self.response(mtype: 2, adm: vast))
        let prepared = try #require(harness.session.prepared)
        let ad = try #require(prepared.vast?.ads.first)
        #expect(ad.impressions == ["https://t.example/imp?p=1.5&cb=[CACHEBUSTING]"], "the exchange's macro is in, the player's is still a template")
        #expect(ad.trackingEvents.map(\.url) == ["https://t.example/start?p=1.5&ph=[ADPLAYHEAD]"])
        guard case let .vast(.xml(bidXML)) = prepared.candidate.markup else {
            Issue.record("the bid keeps its VAST markup")
            return
        }
        #expect(bidXML.contains("${AUCTION_PRICE}"), "the bid keeps its own markup")

        harness.session.rendererHost.report(.video(.creativeView, adIndex: 0))
        await harness.monitor.waitUntilIdle()
        let impression = try #require(harness.monitor.liveEntries.first { $0.category == .impression })
        #expect(impression.template == "https://t.example/imp?p=1.5&cb=[CACHEBUSTING]")
        #expect(impression.url.range(of: #"^https://t\.example/imp\?p=1\.5&cb=[0-9]{8}$"#, options: .regularExpression) != nil, "\(impression.url)")
        #expect(impression.unknownMacros.isEmpty)
    }

    @Test func nativeAdmURLsCarryThePrice() async throws {
        let native = #"""
        {"native":{"ver":"1.2","assets":[{"id":1,"title":{"text":"T"}}],
          "link":{"url":"https://adv.example/?p=${AUCTION_PRICE}","clicktrackers":["https://t.example/click?p=${AUCTION_PRICE}"]},
          "imptrackers":["https://t.example/imp?p=${AUCTION_PRICE}"]}}
        """#
        let harness = try await render(Self.response(mtype: 4, adm: native))
        let ad = try #require(harness.session.prepared?.native)
        #expect(ad.impressionTrackers == ["https://t.example/imp?p=1.5"])
        #expect(ad.link.clickTrackers == ["https://t.example/click?p=1.5"])
        #expect(ad.link.url == "https://adv.example/?p=1.5")
    }

    @Test func htmlAdmCarriesThePrice() async throws {
        let harness = try await render(Self.response(mtype: 1, adm: #"<img src="https://t.example/px?p=${AUCTION_PRICE}">"#))
        #expect(harness.session.renderRequest?.candidate.markup == .html(#"<img src="https://t.example/px?p=1.5">"#))
    }
}
