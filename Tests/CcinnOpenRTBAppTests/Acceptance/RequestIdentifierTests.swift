import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// Spec review, blocker on 0864bf9 (repro P8): wrapper `VASTAdTagURI`s and pasted tag URLs are expanded by the player and
/// fetched in Simulated mode — the default, with no confirmation. They must not carry the pasted request's personal values
/// (a real end user's IFA, IP, location, consent strings) to a third party from the developer's Mac: in Simulated mode those
/// macros are unknown (-1) and `[DEVICEUA]` is the simulated device's User-Agent, the one actually sent. Real mode, after the
/// confirmation, fills them from the request.
@MainActor
@Suite("Acceptance: request identifiers in content fetches", .serialized)
struct RequestIdentifierTests {
    static let request = """
    {"id": "req-1", "imp": [{"id": "1", "video": {"w": 640, "h": 360, "mimes": ["video/mp4"]}}],
     "device": {"ifa": "REAL-USER-IFA-1234", "ip": "203.0.113.7", "ua": "RealUA/1.0 (RealDevice)", "geo": {"lat": 3.139, "lon": 101.6869}},
     "user": {"consent": "CPREALCONSENTSTRING"}, "regs": {"gpp": "DBABMA~CPREALGPP", "gpp_sid": [2]}}
    """
    static let secrets = ["REAL-USER-IFA-1234", "203.0.113.7", "3.139", "101.6869", "CPREALCONSENTSTRING", "CPREALGPP", "RealUA"]
    static let tagQuery = "ifa=[IFA]&ip=[DEVICEIP]&ll=[LATLONG]&gdpr=[GDPRCONSENT]&gpp=[GPPSTRING]&ua=[DEVICEUA]&cb=[CACHEBUSTING]"

    private static func inline() -> String {
        """
        <VAST version="4.1"><Ad id="i"><InLine><AdSystem>t</AdSystem><AdTitle>t</AdTitle><Impression><![CDATA[https://t.example/imp]]></Impression>
          <Creatives><Creative><Linear><Duration>00:00:15</Duration><MediaFiles>
            <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile>
          </MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>
        """
    }

    /// The reviewer's P8 wrapper: a bid response whose VAST adm wraps a tag that asks for the user's identifiers.
    private static func wrapperResponse(base: String) -> String {
        let wrapper = """
        <VAST version="4.1"><Ad id="w"><Wrapper><AdSystem>t</AdSystem>
          <VASTAdTagURI><![CDATA[\(base)/inline.xml?\(tagQuery)]]></VASTAdTagURI>
          <Impression><![CDATA[https://t.example/wrapper-imp]]></Impression></Wrapper></Ad></VAST>
        """
        let adm = JSONValue.string(wrapper).serialized()
        return """
        {"id": "req-1", "seatbid": [{"seat": "dsp", "bid": [{"id": "bid-1", "impid": "1", "price": 1.5, "mtype": 2, "w": 640, "h": 360, "adm": \(adm)}]}]}
        """
    }

    @Test func simulatedTagFetchCarriesNoRequestIdentifiers() async throws {
        let transport = CountingTransport()
        transport.respondByPrefix("https://ad.example/inline.xml", body: Self.inline())
        let harness = AcceptanceSession(transport: transport)
        let sample = Sample(id: "p8", title: "p8", group: "test", response: Self.wrapperResponse(base: "https://ad.example"), request: Self.request)
        try await harness.render(sample)
        #expect(harness.session.mode == .simulated)
        let fetched = try #require(transport.requests.first { $0.url.absoluteString.hasPrefix("https://ad.example/inline.xml") })
        let url = fetched.url.absoluteString
        for secret in Self.secrets { #expect(!url.contains(secret), "\(secret) left the Mac in Simulated mode: \(url)") }
        let device = harness.session.device.userAgent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        #expect(url.contains("ifa=-1&ip=-1&ll=-1&gdpr=-1&gpp=-1&ua="), "\(url)")
        #expect(url.range(of: "ua=([^&]+)&cb=[0-9]{8}$", options: .regularExpression) != nil, "\(url)")
        #expect(!device.isEmpty)
        // The recorded entry shows the same: nothing from the request.
        let entry = try #require(harness.monitor.liveEntries.first { $0.url == url })
        for secret in Self.secrets { #expect(!entry.url.contains(secret)) }
    }

    /// The same tag pasted as the input, with the request: also a Simulated-mode content fetch.
    @Test func simulatedPastedTagCarriesNoRequestIdentifiers() async throws {
        let transport = CountingTransport()
        transport.respondByPrefix("https://ad.example/tag.xml", body: Self.inline())
        let harness = AcceptanceSession(transport: transport)
        let sample = Sample(id: "p8-tag", title: "p8", group: "test", response: "https://ad.example/tag.xml?\(Self.tagQuery)", request: Self.request)
        try await harness.render(sample)
        let url = try #require(transport.requests.first).url.absoluteString
        for secret in Self.secrets { #expect(!url.contains(secret), "\(secret) left the Mac in Simulated mode: \(url)") }
        #expect(url.contains("ifa=-1&ip=-1&ll=-1&gdpr=-1"), "\(url)")
    }

    /// Real mode, after the confirmation: the player fills the request's values in, as a device would.
    @Test func realModeTagFetchCarriesTheRequestValuesAfterConfirmation() async throws {
        let server = try EchoServer()
        let port = try #require(await server.start())
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        let harness = AcceptanceSession(transport: URLSessionTransport())
        let sample = Sample(id: "p8-real", title: "p8", group: "test", response: Self.wrapperResponse(base: base), request: Self.request)
        await harness.session.load(sample, render: false)
        try harness.confirmRealMode()
        harness.session.render()
        await harness.waitUntilSettled()
        let fetched = try #require(server.requests.first { $0.target.hasPrefix("/inline.xml") }, "\(server.requests.map(\.target))")
        #expect(fetched.target.contains("ifa=REAL-USER-IFA-1234&ip=203.0.113.7&ll=3.139,101.6869&gdpr=CPREALCONSENTSTRING"), "\(fetched.target)")
        #expect(fetched.target.contains("ua=RealUA"), "\(fetched.target)")
    }
}
