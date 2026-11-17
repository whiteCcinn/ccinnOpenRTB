import Foundation
import Testing
@testable import RTBKit

enum OpenRTBFixtures {
    /// OpenRTB 2.5 §6.2 example: a bid without `adm` (markup by win notice).
    static let spec25WinNotice = #"""
    {"id":"1234567890","bidid":"abc1123","cur":"USD","seatbid":[{"seat":"512","bid":[{"id":"1","impid":"102","price":9.43,
      "nurl":"http://adserver.com/winnotice?impid=102","iurl":"http://adserver.com/pathtosampleimage","adomain":["advertiserdomain.com"],
      "cid":"campaign111","crid":"creative112","attr":[1,2,3,4,5,6,7,12]}]}]}
    """#

    static let vast = #"<VAST version="4.0"><Ad id="1"><InLine><AdSystem>A</AdSystem><AdTitle>T</AdTitle></InLine></Ad></VAST>"#

    static func response26Video(adm: String = vast) -> String {
        let escaped = String(data: (try? JSONSerialization.data(withJSONObject: [adm], options: [])) ?? Data(), encoding: .utf8)?
            .dropFirst().dropLast() ?? "\"\""
        return #"{"id":"req-1","seatbid":[{"seat":"dsp","bid":[{"id":"b1","impid":"1","price":4.2,"mtype":2,"adm":"# + escaped
            + #","burl":"https://t.example/bill?p=${AUCTION_PRICE}","adomain":["brand.example"],"crid":"cr-1","w":640,"h":360,"ext":{"x":1}}]}]}"#
    }

    /// OpenRTB 3.0 example shape: AdCOM display banner (structured image) with an event.
    static let spec30Banner = #"""
    {"openrtb":{"ver":"3.0","domainspec":"adcom","domainver":"1.0","response":{"id":"0123456789ABCDEF","bidid":"0011223344AABBCC",
      "seatbid":[{"seat":"XYZ","bid":[{"id":"yaddayadda","item":"1","price":1.50,"deal":"1234","cid":"cmp-1",
        "purl":"https://adserver.example/win?price=${OPENRTB_PRICE}","burl":"https://adserver.example/bill?price=${OPENRTB_PRICE}",
        "lurl":"https://adserver.example/loss?r=${OPENRTB_LOSS}",
        "macro":[{"key":"TIMESTAMP","value":"1127987134"},{"key":"CLICKTOKEN","value":"A7D800F2716DB"}],
        "media":{"ad":{"id":"555555","adomain":["ford.com"],"bundle":["com.ford.app"],"secure":1,
          "display":{"mime":"image/jpeg","ctype":3,"w":320,"h":50,
            "banner":{"img":"https://somecdn.example/creative.jpg","link":{"url":"https://adserver.example/click?tok=${CUSTOM_CLICKTOKEN}","trkr":["https://t.example/c"]}},
            "event":[{"type":1,"method":1,"url":"https://t.example/loaded"},{"type":2,"method":1,"url":"https://t.example/imp"},
                     {"type":3,"method":2,"url":"https://t.example/view.js"}]}}}}]}]}}}
    """#

    static func spec30(display: String? = nil, video: String? = nil, audio: String? = nil, extraBid: String = "") -> String {
        var media: [String] = []
        if let display { media.append(#""display":"# + display) }
        if let video { media.append(#""video":"# + video) }
        if let audio { media.append(#""audio":"# + audio) }
        return #"{"openrtb":{"ver":"3.0","domainver":"1.0","response":{"id":"r","seatbid":[{"bid":[{"id":"b","item":"1","price":1"#
            + extraBid + #","media":{"ad":{"id":"a","# + media.joined(separator: ",") + "}}}]}]}}}"
    }

    static let request26 = #"""
    {"id":"req-1","cur":["USD","EUR"],"imp":[
       {"id":"1","banner":{"format":[{"w":320,"h":50},{"w":300,"h":250}]},"secure":1},
       {"id":"2","video":{"w":640,"h":360,"mimes":["video/mp4"]}},
       {"id":"3","native":{"ver":"1.2","request":"{\"ver\":\"1.2\",\"assets\":[{\"id\":1,\"required\":1,\"title\":{\"len\":20}},{\"id\":2,\"img\":{\"type\":3,\"w\":1200,\"h\":627}},{\"id\":3,\"data\":{\"type\":2}}]}"},"secure":1},
       {"id":"4","banner":{"w":300,"h":250},"video":{"w":640,"h":480}}],
     "device":{"devicetype":4,"ua":"UA","ifa":"IFA-1","lmt":0},"app":{"bundle":"com.example.app"}}
    """#
}

private func issue(_ code: String, in input: ParsedInput) -> ValidationIssue? {
    input.issues.first { $0.code == code }
}

@Suite("InputParser – detection (D3)")
struct InputDetectionTests {
    @Test func emptyInput() {
        #expect(InputParser.parse("  \n ").kind == .empty)
    }

    @Test func vastMarkup() throws {
        let input = InputParser.parse("<?xml version=\"1.0\"?>\n<!-- served by X -->\n" + OpenRTBFixtures.vast)
        #expect(input.kind == .vastMarkup)
        let candidate = try #require(input.candidates.first)
        #expect(candidate.format == .video)
        guard case .vast(.xml) = candidate.markup else { Issue.record("expected VAST XML"); return }
    }

    @Test func vastURL() {
        let input = InputParser.parse(" https://ads.example/vast?id=1&cb=[CACHEBUSTING] ")
        #expect(input.kind == .vastURL)
        #expect(input.candidates.first?.markup == .vast(.url("https://ads.example/vast?id=1&cb=[CACHEBUSTING]")))
    }

    @Test func htmlEvenWhenItMentionsVAST() {
        let input = InputParser.parse("<div><script>var tag = '<VAST version=\"3.0\">';</script></div>")
        #expect(input.kind == .htmlMarkup)
        #expect(input.candidates.first?.format == .banner)
    }

    @Test func openRTB3BeforeOpenRTB2() {
        #expect(InputParser.parse(OpenRTBFixtures.spec30Banner).kind == .bidResponse(.v3("3.0")))
    }

    @Test func openRTB2() {
        #expect(InputParser.parse(OpenRTBFixtures.spec25WinNotice).kind == .bidResponse(.v2("2.x")))
        #expect(InputParser.parse(#"{"id":"a","nbr":2}"#).kind == .bidResponse(.v2("2.x")))
    }

    @Test func bareNative() {
        let input = InputParser.parse(NativeFixtures.response10)
        #expect(input.kind == .nativeMarkup)
        #expect(input.candidates.first?.format == .native)
    }

    @Test func invalidInputsSayWhy() {
        guard case let .invalid(reason) = InputParser.parse(#"{"id": "x", "seatbid": [}"#).kind else { Issue.record("invalid JSON"); return }
        #expect(reason.hasPrefix("Invalid JSON"))
        guard case let .invalid(request) = InputParser.parse(OpenRTBFixtures.request26).kind else { Issue.record("a request"); return }
        #expect(request.contains("bid request"))
        guard case .invalid = InputParser.parse("hello world").kind else { Issue.record("plain text"); return }
        guard case .invalid = InputParser.parse(#"{"foo":1}"#).kind else { Issue.record("unrelated JSON"); return }
        guard case .invalid = InputParser.parse("[1,2,3]").kind else { Issue.record("array"); return }
    }
}

@Suite("InputParser – OpenRTB 2.x")
struct OpenRTB2Tests {
    @Test func winNoticeMarkupSpecExample() throws {
        let input = InputParser.parse(OpenRTBFixtures.spec25WinNotice)
        #expect(input.responseID == "1234567890")
        #expect(input.bidResponseID == "abc1123")
        #expect(input.currency == "USD")
        let bid = try #require(input.candidates.first)
        #expect(bid.id == "0.0")
        #expect(bid.bidID == "1")
        #expect(bid.impID == "102")
        #expect(bid.seat == "512")
        #expect(bid.price == 9.43)
        #expect(bid.campaignID == "campaign111")
        #expect(bid.creativeID == "creative112")
        #expect(bid.advertiserDomains == ["advertiserdomain.com"])
        #expect(bid.markup == .none)
        #expect(bid.winURL == "http://adserver.com/winnotice?impid=102")
        let info = try #require(issue("openrtb.bid.markup.winnotice", in: input))
        #expect(info.severity == .info)
        #expect(info.path == "/seatbid/0/bid/0/adm")
        #expect(!input.issues.contains { $0.severity == .error })
    }

    @Test func openRTB26VideoBidScenario() throws {
        // response-input spec: mtype 2 + VAST adm → "OpenRTB 2.6 bid response", format Video.
        let input = InputParser.parse(OpenRTBFixtures.response26Video())
        #expect(input.kind == .bidResponse(.v2("2.6")))
        #expect(OpenRTBVersion.v2("2.6").description == "OpenRTB 2.6")
        let bid = try #require(input.candidates.first)
        #expect(bid.format == .video)
        #expect(bid.markup == .vast(.xml(OpenRTBFixtures.vast)))
        #expect(bid.markupType == 2)
        #expect(bid.size == AdSize(width: 640, height: 360))
        #expect(bid.billingURL == "https://t.example/bill?p=${AUCTION_PRICE}")
        #expect(bid.ext == ["x": 1])
        #expect(input.issues.isEmpty, "\(input.issues)")
    }

    @Test func versionInference() {
        let burl = #"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"<p/>","burl":"https://t.example/b"}]}]}"#
        #expect(InputParser.parse(burl).kind == .bidResponse(.v2("2.5")))
        let plain = #"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"<p/>"}]}]}"#
        #expect(InputParser.parse(plain).kind == .bidResponse(.v2("2.x")))
        let declared = #"{"id":"r","ver":"2.3","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"<p/>"}]}]}"#
        #expect(InputParser.parse(declared).kind == .bidResponse(.v2("2.3")))
        // Every Bid field OpenRTB 2.6 introduced proves 2.6.
        for field in [#""mtype":1"#, #""slotinpod":1"#, #""dur":15"#, #""cattax":2"#, #""langb":"en""#, #""apis":[7]"#] {
            let json = #"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"<p/>","# + field + "}]}]}"
            #expect(InputParser.parse(json).kind == .bidResponse(.v2("2.6")), "\(field)")
        }
    }

    @Test func burlInADeclaredOlderVersionIsInfo() throws {
        let json = #"{"id":"r","ver":"2.3","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"<p/>","lurl":"https://t.example/l"}]}]}"#
        let input = InputParser.parse(json)
        let found = try #require(issue("openrtb.version.field", in: input))
        #expect(found.severity == .info)
        #expect(found.path == "/seatbid/0/bid/0/lurl")
        #expect(input.kind == .bidResponse(.v2("2.5")))
    }

    @Test func formatInference() throws {
        // No mtype, no request: the adm decides.
        let native = #"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"{\"native\":{\"assets\":[{\"id\":1,\"title\":{\"text\":\"T\"}}],\"link\":{\"url\":\"https://l\"}}}"}]}]}"#
        #expect(InputParser.parse(native).candidates.first?.format == .native)
        let vast = OpenRTBFixtures.response26Video().replacingOccurrences(of: #""mtype":2,"#, with: "")
        #expect(InputParser.parse(vast).candidates.first?.format == .video)

        // The impression's only type wins over the sniff (and the mismatch is reported).
        let html = #"{"id":"req-1","seatbid":[{"bid":[{"id":"b","impid":"2","price":1,"adm":"<div>ad</div>"}]}]}"#
        let input = InputParser.parse(html, request: OpenRTBFixtures.request26)
        #expect(input.candidates.first?.format == .video)
        #expect(issue("openrtb.bid.markup.mismatch", in: input) != nil)

        // A multi-format impression: the sniff picks among the offered types.
        let multi = OpenRTBFixtures.response26Video().replacingOccurrences(of: #""mtype":2,"#, with: "")
            .replacingOccurrences(of: #""impid":"1""#, with: #""impid":"4""#)
        #expect(InputParser.parse(multi, request: OpenRTBFixtures.request26).candidates.first?.format == .video)
    }

    @Test func audioFromMtype3() throws {
        let audio = #"<VAST version="4.0"><Ad><InLine><Creatives><Creative><Linear><MediaFiles><MediaFile type="audio/mp4" delivery="progressive">https://a/x.m4a</MediaFile></MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>"#
        let input = InputParser.parse(OpenRTBFixtures.response26Video(adm: audio).replacingOccurrences(of: #""mtype":2"#, with: #""mtype":3"#))
        #expect(input.candidates.first?.format == .audio)
        // Without mtype the audio-only VAST is sniffed as audio too.
        #expect(InputParser.parse(OpenRTBFixtures.response26Video(adm: audio).replacingOccurrences(of: #""mtype":2,"#, with: "")).candidates.first?.format == .audio)
    }

    @Test func requiredFieldsAreErrors() throws {
        let input = InputParser.parse(#"{"seatbid":[{"bid":[{"adm":"<p/>"}]},{"seat":"empty"}]}"#)
        for code in ["openrtb.response.id.missing", "openrtb.bid.id.missing", "openrtb.bid.impid.missing", "openrtb.bid.price.missing",
                     "openrtb.seatbid.bid.missing"] {
            #expect(issue(code, in: input)?.severity == .error, "\(code)")
        }
        #expect(issue("openrtb.seatbid.bid.missing", in: input)?.path == "/seatbid/1/bid")
        #expect(input.candidates.count == 1)
    }

    @Test func markupAndWinNoticeAbsentIsAnError() throws {
        let input = InputParser.parse(#"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"  "}]}]}"#)
        #expect(issue("openrtb.bid.markup.missing", in: input)?.severity == .error)
        #expect(input.candidates.first?.markup == AdMarkup.none)
    }

    @Test func priceRules() throws {
        let zero = InputParser.parse(#"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":0,"adm":"<p/>"}]}]}"#)
        #expect(issue("openrtb.bid.price.nonpositive", in: zero)?.severity == .warning)
        let text = InputParser.parse(#"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":"2.5","adm":"<p/>"}]}]}"#)
        #expect(text.candidates.first?.price == 2.5)
        #expect(issue("openrtb.type.mismatch", in: text)?.path == "/seatbid/0/bid/0/price")
        let huge = InputParser.parse(#"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1e308,"adm":"<p/>"}]}]}"#)
        #expect(huge.candidates.first?.price == 1e308)
    }

    @Test func currencyRules() throws {
        let bad = InputParser.parse(#"{"id":"r","cur":"usd","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"<p/>"}]}]}"#)
        #expect(issue("openrtb.response.cur.invalid", in: bad)?.severity == .warning)
        #expect(issue("openrtb.response.cur.invalid", in: bad)?.path == "/cur")
        let unrequested = InputParser.parse(#"{"id":"req-1","cur":"JPY","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"<p/>"}]}]}"#,
                                            request: OpenRTBFixtures.request26)
        #expect(issue("openrtb.response.cur.unrequested", in: unrequested) != nil)
        #expect(issue("openrtb.response.cur.invalid", in: unrequested) == nil)
        #expect(InputParser.parse(OpenRTBFixtures.spec25WinNotice).candidates.first?.currency == "USD")
    }

    @Test func mtypeOutOfRangeIsAnError() throws {
        let input = InputParser.parse(#"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"mtype":5,"adm":"<p/>"}]}]}"#)
        let found = try #require(issue("openrtb.bid.mtype.invalid", in: input))
        #expect(found.severity == .error)
        #expect(found.path == "/seatbid/0/bid/0/mtype")
        #expect(input.candidates.first?.format == .banner)
    }

    @Test func noBidScenario() throws {
        // response-input spec: {"id": "a", "nbr": 2} → "No bid", reason named.
        let input = InputParser.parse(#"{"id": "a", "nbr": 2}"#)
        #expect(input.noBidReason == 2)
        #expect(input.candidates.isEmpty)
        #expect(issue("openrtb.response.nobid", in: input)?.message == "No bid: 2 – Invalid Request.")
        #expect(!input.issues.contains { $0.severity != .info })
    }

    @Test func requestCrossChecks() throws {
        let json = #"{"id":"other","seatbid":[{"bid":[{"id":"b","impid":"9","price":1,"adm":"<p/>"},{"id":"b","impid":"2","price":1,"mtype":1,"adm":"<p/>"}]}]}"#
        let input = InputParser.parse(json, request: OpenRTBFixtures.request26)
        #expect(issue("openrtb.response.id.mismatch", in: input) != nil)
        #expect(issue("openrtb.bid.impid.unknown", in: input)?.path == "/seatbid/0/bid/0/impid")
        #expect(issue("openrtb.bid.format.unrequested", in: input)?.path == "/seatbid/0/bid/1/mtype")
        #expect(issue("openrtb.bid.id.duplicate", in: input)?.path == "/seatbid/0/bid/1/id")
    }

    @Test func nativeBidIssuesAreIncludedUnderTheAdmPointer() throws {
        let adm = #"{\"ver\":\"1.2\",\"assets\":[{\"id\":2,\"img\":{\"url\":\"http://cdn.example/m.png\"}}],\"link\":{\"url\":\"https://l\",\"clicktrackers\":[\"http://t.example/c\"]},\"eventtrackers\":[{\"event\":1,\"method\":1,\"url\":\"http://t.example/i\"}]}"#
        let json = #"{"id":"req-1","seatbid":[{"bid":[{"id":"b","impid":"3","price":1,"mtype":4,"adm":""# + adm + #""}]}]}"#
        let input = InputParser.parse(json, request: OpenRTBFixtures.request26)
        // Title (asset 1) is required by the request.
        #expect(issue("native.asset.required.missing", in: input)?.path == "/seatbid/0/bid/0/adm/assets")
        // imp 3 is secure: plain-HTTP trackers and images are flagged with exact pointers.
        let insecure = input.issues.filter { $0.code == "openrtb.tracker.insecure" }.map(\.path)
        #expect(insecure == ["/seatbid/0/bid/0/adm/eventtrackers/0/url", "/seatbid/0/bid/0/adm/link/clicktrackers/0"])
        #expect(issue("openrtb.asset.insecure", in: input)?.path == "/seatbid/0/bid/0/adm/assets/0")
        // Image type 3 from the request.
        let markup = try #require(input.candidates.first?.markup)
        guard case let .native(json) = markup else { Issue.record("native"); return }
        let hints = input.request?.impressions[2].nativeHints
        let parsed = NativeParser.parse(json, hints: hints)
        let ad = try #require(parsed.ad)
        #expect(ad.assets.first?.typeSource == .request)
    }

    @Test func nativeObjectInAdmIsAcceptedWithAWarning() throws {
        let input = InputParser.parse(#"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"mtype":4,"adm":{"assets":[{"id":1,"title":{"text":"T"}}],"link":{"url":"https://l"}}}]}]}"#)
        guard case let .native(json)? = input.candidates.first?.markup else { Issue.record("native"); return }
        #expect(NativeParser.parse(json).ad?.assets.count == 1)
        #expect(issue("openrtb.type.mismatch", in: input)?.path == "/seatbid/0/bid/0/adm")
    }

    @Test func invalidTrackerURLsAreWarnings() {
        let input = InputParser.parse(#"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"adm":"<p/>","nurl":"/relative","burl":"https://ok.example/${AUCTION_PRICE}"}]}]}"#)
        #expect(input.issues.filter { $0.code == "openrtb.url.invalid" }.map(\.path) == ["/seatbid/0/bid/0/nurl"])
    }

    @Test func openRTB3BidFieldsWithoutTheEnvelopeAreFlagged() throws {
        // A 3.0 response pasted without its `openrtb` envelope is read as 2.x; each 3.0-only Bid field says why it is ignored.
        let json = #"{"id":"r","seatbid":[{"bid":[{"id":"b","item":"1","price":1,"purl":"https://t.example/w","media":{"ad":{"id":"a"}},"macro":[]}]}]}"#
        let input = InputParser.parse(json)
        #expect(input.kind == .bidResponse(.v2("2.x")))
        let flagged = input.issues.filter { $0.code == "openrtb.bid.field.v3" }
        #expect(flagged.map(\.path) == ["/seatbid/0/bid/0/item", "/seatbid/0/bid/0/macro", "/seatbid/0/bid/0/media", "/seatbid/0/bid/0/purl"])
        #expect(flagged.allSatisfy { $0.severity == .warning && $0.message.contains("openrtb") })
        #expect(issue("openrtb.bid.field.v3", in: InputParser.parse(OpenRTBFixtures.response26Video())) == nil)
    }

    @Test func dataURLsAreDecodedLocallyAndReportedAsInfo() throws {
        // A `data:` URL is a valid URL the simulator decodes offline; production exchanges and devices expect http(s).
        let input = InputParser.parse(#"{"id":"r","seatbid":[{"bid":[{"id":"b","impid":"1","price":1,"nurl":"data:text/html;base64,PHA+YWQ8L3A+"}]}]}"#)
        let found = try #require(issue("openrtb.url.data", in: input))
        #expect(found.severity == .info)
        #expect(found.path == "/seatbid/0/bid/0/nurl")
        #expect(issue("openrtb.url.invalid", in: input) == nil)
        let curl = InputParser.parse(OpenRTBFixtures.spec30(display: #"{"curl":"data:text/html;base64,PHA+YWQ8L3A+"}"#))
        #expect(issue("openrtb.url.data", in: curl)?.path == "/openrtb/response/seatbid/0/bid/0/media/ad/display/curl")
        #expect(!curl.issues.contains { $0.severity != .info })
    }

    @Test func multipleSeatsAndBidsAreAllListed() {
        let json = #"{"id":"r","seatbid":[{"seat":"a","bid":[{"id":"1","impid":"1","price":1,"adm":"<p/>"},{"id":"2","impid":"1","price":2,"adm":"<p/>"}]},{"seat":"b","bid":[{"id":"3","impid":"1","price":3,"adm":"<p/>"}]}]}"#
        let input = InputParser.parse(json)
        #expect(input.candidates.map(\.id) == ["0.0", "0.1", "1.0"])
        #expect(input.candidates.map(\.seat) == ["a", "a", "b"])
    }
}

@Suite("InputParser – OpenRTB 3.0 / AdCOM")
struct OpenRTB3Tests {
    @Test func displayBannerImage() throws {
        let input = InputParser.parse(OpenRTBFixtures.spec30Banner)
        #expect(input.kind == .bidResponse(.v3("3.0")))
        #expect(input.responseID == "0123456789ABCDEF")
        #expect(input.bidResponseID == "0011223344AABBCC")
        let bid = try #require(input.candidates.first)
        #expect(bid.bidID == "yaddayadda")
        #expect(bid.impID == "1")
        #expect(bid.seat == "XYZ")
        #expect(bid.dealID == "1234")
        #expect(bid.creativeID == "555555")
        #expect(bid.bundle == "com.ford.app")
        #expect(bid.format == .banner)
        #expect(bid.size == AdSize(width: 320, height: 50))
        #expect(bid.markup == .image(ImageBanner(imageURL: "https://somecdn.example/creative.jpg",
                                                 link: AdLink(url: "https://adserver.example/click?tok=${CUSTOM_CLICKTOKEN}",
                                                              clickTrackers: ["https://t.example/c"]))))
        #expect(bid.winURL == "https://adserver.example/win?price=${OPENRTB_PRICE}")
        #expect(bid.lossURL == "https://adserver.example/loss?r=${OPENRTB_LOSS}")
        #expect(bid.customMacros == ["TIMESTAMP": "1127987134", "CLICKTOKEN": "A7D800F2716DB"])
        #expect(bid.adcomEvents == [AdcomEvent(type: 1, method: 1, url: "https://t.example/loaded"),
                                    AdcomEvent(type: 2, method: 1, url: "https://t.example/imp"),
                                    AdcomEvent(type: 3, method: 2, url: "https://t.example/view.js")])
        #expect(input.issues.isEmpty, "\(input.issues)")
    }

    @Test func displayNativeScenario() throws {
        // response-input spec: media.ad.display.native with assets → Native.
        let native = #"{"native":{"link":{"url":"https://l.example"},"asset":[{"id":1,"title":{"text":"Hi"}},{"id":2,"image":{"url":"https://cdn.example/m.png","type":3}}]}}"#
        let input = InputParser.parse(OpenRTBFixtures.spec30(display: native))
        let bid = try #require(input.candidates.first)
        #expect(bid.format == .native)
        guard case let .native(json) = bid.markup else { Issue.record("native markup"); return }
        let ad = try #require(NativeParser.parse(json).ad)
        #expect(ad.assets.count == 2)
        #expect(ad.link.url == "https://l.example")
        #expect(input.issues.isEmpty, "\(input.issues)")
    }

    @Test func displayNativeIssuesPointIntoTheResponse() throws {
        let native = #"{"native":{"asset":[{"id":1,"title":{"text":"Hi"}},{"id":1,"title":{"text":"Again"}}]}}"#
        let input = InputParser.parse(OpenRTBFixtures.spec30(display: native))
        #expect(issue("native.asset.id.duplicate", in: input)?.path == "/openrtb/response/seatbid/0/bid/0/media/ad/display/native/asset/1/id")
    }

    @Test func displayAdmAndCurl() throws {
        let adm = InputParser.parse(OpenRTBFixtures.spec30(display: #"{"w":300,"h":250,"adm":"<div>ad</div>"}"#))
        #expect(adm.candidates.first?.markup == .html("<div>ad</div>"))
        let curl = InputParser.parse(OpenRTBFixtures.spec30(display: #"{"curl":"https://markup.example/ad.html"}"#))
        let bid = try #require(curl.candidates.first)
        #expect(bid.markup == AdMarkup.none)
        #expect(bid.markupURL == "https://markup.example/ad.html")
        #expect(issue("adcom.display.curl", in: curl)?.severity == .info)
        #expect(issue("adcom.display.curl", in: curl)?.path == "/openrtb/response/seatbid/0/bid/0/media/ad/display/curl")
    }

    @Test func videoAndAudio() throws {
        let video = InputParser.parse(OpenRTBFixtures.spec30(video: #"{"mime":["video/mp4"],"adm":"<VAST version=\"3.0\"></VAST>"}"#))
        #expect(video.candidates.first?.format == .video)
        #expect(video.candidates.first?.markup == .vast(.xml(#"<VAST version="3.0"></VAST>"#)))
        let tag = InputParser.parse(OpenRTBFixtures.spec30(video: #"{"curl":"https://vast.example/tag"}"#))
        #expect(tag.candidates.first?.markup == .vast(.url("https://vast.example/tag")))
        let audio = InputParser.parse(OpenRTBFixtures.spec30(audio: #"{"adm":"<VAST version=\"4.1\"></VAST>"}"#))
        #expect(audio.candidates.first?.format == .audio)
    }

    @Test func requiredFieldsAndEvents() throws {
        let json = #"{"openrtb":{"ver":"3.0","response":{"id":"r","seatbid":[{"bid":[{"price":1,"nurl":"https://x.example","media":{"ad":{"display":{"adm":"<p/>","event":[{"type":9,"method":4,"url":"https://t"},{"type":2,"method":2,"jstrk":"<script>t()</script>"},{"type":2}]}}}}]}]}}}"#
        let input = InputParser.parse(json)
        #expect(issue("openrtb3.domainver.missing", in: input)?.severity == .error)
        #expect(issue("openrtb3.bid.item.missing", in: input)?.severity == .error)
        #expect(issue("adcom.ad.id.missing", in: input)?.severity == .error)
        #expect(issue("openrtb3.bid.nurl", in: input)?.severity == .warning)
        #expect(issue("adcom.event.type.invalid", in: input)?.path == "/openrtb/response/seatbid/0/bid/0/media/ad/display/event/0/type")
        #expect(issue("adcom.event.method.invalid", in: input) != nil)
        #expect(issue("adcom.event.incomplete", in: input) != nil)
        #expect(input.candidates.first?.adcomEvents.last == AdcomEvent(type: 2, method: 2, script: "<script>t()</script>"))
    }

    @Test func mediaMissing() {
        let input = InputParser.parse(#"{"openrtb":{"ver":"3.0","domainver":"1.0","response":{"id":"r","seatbid":[{"bid":[{"item":"1","price":1}]}]}}}"#)
        #expect(issue("openrtb3.bid.media.missing", in: input)?.severity == .error)
        #expect(input.candidates.first?.markup == AdMarkup.none)
    }

    @Test func insecureEventOnASecureItem() {
        let request = #"{"openrtb":{"ver":"3.0","domainver":"1.0","request":{"id":"r","item":[{"id":"1","spec":{"placement":{"secure":1,"display":{"w":320,"h":50}}}}]}}}"#
        let json = OpenRTBFixtures.spec30(display: #"{"adm":"<p/>","event":[{"type":2,"method":1,"url":"http://t.example/i"}]}"#)
        let input = InputParser.parse(json, request: request)
        #expect(issue("openrtb.tracker.insecure", in: input)?.path == "/openrtb/response/seatbid/0/bid/0/media/ad/display/event/0/url")
    }
}

@Suite("InputParser – bid request summary")
struct BidRequestSummaryTests {
    @Test func openRTB2Request() throws {
        let input = InputParser.parse(OpenRTBFixtures.response26Video(), request: OpenRTBFixtures.request26)
        let request = try #require(input.request)
        #expect(request.id == "req-1")
        #expect(request.currencies == ["USD", "EUR"])
        #expect(request.deviceType == 4)
        #expect(request.impressions.map(\.id) == ["1", "2", "3", "4"])
        #expect(request.impressions[0] == BidRequestSummary.Impression(id: "1", formats: [.banner], size: AdSize(width: 320, height: 50), secure: true))
        #expect(request.impressions[1].formats == [.video])
        #expect(request.impressions[1].size == AdSize(width: 640, height: 360))
        let hints = try #require(request.impressions[2].nativeHints)
        #expect(hints.version == "1.2")
        #expect(hints.required == [1])
        #expect(hints.assets[2] == .image(type: .main, width: 1200, height: 627))
        #expect(hints.assets[3] == .data(type: .description, maxLength: nil))
        #expect(request.impressions[3].formats == [.banner, .video])
    }

    @Test func openRTB3Request() throws {
        let request = #"""
        {"openrtb":{"ver":"3.0","domainver":"1.0","request":{"id":"r3","cur":["USD"],"item":[
          {"id":"1","spec":{"placement":{"secure":1,"display":{"displayfmt":[{"w":300,"h":250}],"nativefmt":{"asset":[{"id":1,"req":1,"title":{"len":30}}]}}}}},
          {"id":"2","spec":{"placement":{"video":{"w":1920,"h":1080}}}}],
          "context":{"device":{"type":3}}}}}
        """#
        let summary = try #require(InputParser.parse(OpenRTBFixtures.spec30Banner, request: request).request)
        #expect(summary.id == "r3")
        #expect(summary.deviceType == 3)
        #expect(summary.impressions[0].formats == [.native])
        #expect(summary.impressions[0].secure)
        #expect(summary.impressions[0].size == AdSize(width: 300, height: 250))
        #expect(summary.impressions[0].nativeHints?.required == [1])
        #expect(summary.impressions[1].formats == [.video])
    }

    @Test func requestDerivedMacroFieldsFromAnApp() throws {
        let summary = try #require(InputParser.parse(OpenRTBFixtures.response26Video(), request: OpenRTBFixtures.request26).request)
        #expect(summary.appBundle == "com.example.app")
        #expect(summary.ifa == "IFA-1")
        #expect(summary.limitAdTracking == false)
        #expect(summary.domain == nil)
        #expect(summary.pageURL == nil)
        #expect(summary.transactionID == nil)
        let withDomain = #"{"id":"r","imp":[{"id":"1","banner":{"w":1,"h":1}}],"app":{"bundle":"b","domain":"app.example"},"device":{"lmt":1}}"#
        let app = try #require(InputParser.parse(OpenRTBFixtures.spec25WinNotice, request: withDomain).request)
        #expect(app.domain == "app.example")
        #expect(app.limitAdTracking == true)
    }

    @Test func requestDerivedMacroFieldsFromASite() throws {
        let request = #"""
        {"id":"r","imp":[{"id":"1","banner":{"w":300,"h":250}}],"site":{"domain":"news.example","page":"https://news.example/a?b=1"},
         "source":{"tid":"tx-1"}}
        """#
        let summary = try #require(InputParser.parse(OpenRTBFixtures.spec25WinNotice, request: request).request)
        #expect(summary.domain == "news.example")
        #expect(summary.pageURL == "https://news.example/a?b=1")
        #expect(summary.transactionID == "tx-1")
        #expect(summary.appBundle == nil)
        // Without `site.domain`, the page's host is the domain of the top-level page.
        let pageOnly = #"{"id":"r","imp":[{"id":"1","banner":{"w":1,"h":1}}],"site":{"page":"https://www.example.org/x"}}"#
        #expect(InputParser.parse(OpenRTBFixtures.spec25WinNotice, request: pageOnly).request?.domain == "www.example.org")
    }

    @Test func requestDerivedMacroFieldsFromAnOpenRTB3Request() throws {
        let request = #"""
        {"openrtb":{"ver":"3.0","domainver":"1.0","request":{"id":"r3","source":{"tid":"tx-3"},"item":[{"id":"1","spec":{"placement":{"display":{"w":320,"h":50}}}}],
          "context":{"app":{"bundle":"com.example.three","domain":"three.example"},"device":{"type":4,"ifa":"IFA-3","lmt":1}}}}}
        """#
        let summary = try #require(InputParser.parse(OpenRTBFixtures.spec30Banner, request: request).request)
        #expect(summary.appBundle == "com.example.three")
        #expect(summary.domain == "three.example")
        #expect(summary.ifa == "IFA-3")
        #expect(summary.limitAdTracking == true)
        #expect(summary.transactionID == "tx-3")
    }

    @Test func invalidRequestIsAWarningAndIgnored() {
        let input = InputParser.parse(OpenRTBFixtures.spec25WinNotice, request: "{not json")
        #expect(input.request == nil)
        #expect(issue("request.json.invalid", in: input)?.severity == .warning)
        #expect(issue("request.json.invalid", in: input)?.path == "request:")
    }

    @Test func bareMarkupUsesTheRequestImpression() {
        let input = InputParser.parse("<div>ad</div>", request: OpenRTBFixtures.request26)
        #expect(input.candidates.first?.impID == "1")
        #expect(input.candidates.first?.size == AdSize(width: 320, height: 50))
        #expect(input.candidates.first?.currency == "USD")
    }
}
