import Foundation
import Testing
@testable import RTBKit

/// Which macro family a URL's fire-time expansion substitutes depends on the document the URL was written in
/// (decisions.md "Macros", "VAST macro rulings"):
/// - OpenRTB 2.6 §4.4 (3.0 likewise): the exchange substitutes `${…}`, in the bid response's own URLs (nurl/burl/lurl,
///   3.0 purl/burl/lurl, AdCOM `display.event`, the AdCOM banner `link`) and in the `adm` it passes on. The app performs
///   that `adm` substitution before parsing, so inline VAST and Native arrive already substituted.
/// - VAST 4.1 §6.1/§6.2: a player expands only VAST `[…]` macros, in every VAST document of the chain.
/// - Documents a request delivered (markup from the win notice or AdCOM `curl`, a VAST tag URL, a wrapper hop) never
///   went through the exchange: a `${…}` left there stays literal, is listed in `unknownMacros`, and VAST resolution warns
///   once per such document (`vast.macro.openrtb.unsubstituted`).
/// - Native trackers and links (Native 1.2 §5) are fired by the SDK as written: nothing expands at fire time.
@Suite("Macros by document origin")
struct MacroOriginTests {
    /// One URL with one macro of each family: OpenRTB `${AUCTION_PRICE}`, VAST `[CACHEBUSTING]` and `[ERRORCODE]`.
    static let template = "https://t.example/px?p=${AUCTION_PRICE}&cb=[CACHEBUSTING]&e=[ERRORCODE]"
    static let context = MacroContext(auctionID: "auc", price: 1.23, cacheBuster: "12345678")
    static let unsubstituted = "vast.macro.openrtb.unsubstituted"

    static let inlineVAST = """
    <VAST version="3.0"><Ad id="a"><InLine><AdSystem>S</AdSystem><AdTitle>T</AdTitle>
    <Impression><![CDATA[https://t.example/imp]]></Impression>
    <Error><![CDATA[\(template)]]></Error>
    <Creatives><Creative><Linear><Duration>00:00:15</Duration><MediaFiles>
    <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720"><![CDATA[https://cdn.example/a.mp4]]></MediaFile>
    </MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>
    """

    static func wrapperVAST(adTagURI: String) -> String {
        """
        <VAST version="3.0"><Ad id="w"><Wrapper><AdSystem>S</AdSystem>
        <VASTAdTagURI><![CDATA[\(adTagURI)]]></VASTAdTagURI>
        <Impression><![CDATA[https://t.example/wimp]]></Impression>
        <Error><![CDATA[\(template)&k=w]]></Error>
        </Wrapper></Ad></VAST>
        """
    }

    /// What the exchange (the app, for inline `adm`) does to markup before it reaches the player or SDK.
    static func exchangeSubstituted(_ markup: String) -> String {
        MacroExpander.expandMarkup(markup, context: context).url
    }

    /// The Error URLs fired for error 403 on ad 0, with their unknown macros.
    static func errorURLs(_ vast: ResolvedVAST) -> [String] {
        VASTTrackingPlan.requests(for: .error(.noSupportedMedia, adIndex: 0), vast: vast, candidate: nil, context: context, source: "bid 0.0")
            .map(\.url)
    }

    static func errorUnknowns(_ vast: ResolvedVAST) -> [[String]] {
        VASTTrackingPlan.requests(for: .error(.noSupportedMedia, adIndex: 0), vast: vast, candidate: nil, context: context, source: "bid 0.0")
            .map(\.unknownMacros)
    }

    static func unsubstitutedIssues(_ vast: ResolvedVAST) -> [ValidationIssue] {
        vast.issues.filter { $0.code == unsubstituted }
    }

    // MARK: - Expander entry points

    /// VAST 4.1 §6.1: the player replaces `[…]`; `${…}` is not a VAST macro, so it stays literal and is reported, as are
    /// its percent-encoded forms.
    @Test func expandVASTSubstitutesOnlyVASTMacros() {
        let result = MacroExpander.expandVAST(Self.template + "&q=%24%7BAUCTION_ID%7D", context: MacroContext(price: 1.23, errorCode: 403,
                                                                                                              cacheBuster: "12345678"))
        #expect(result.url == "https://t.example/px?p=${AUCTION_PRICE}&cb=12345678&e=403&q=%24%7BAUCTION_ID%7D")
        #expect(result.replaced == ["[CACHEBUSTING]", "[ERRORCODE]"])
        #expect(result.unknown == ["${AUCTION_PRICE}", "%24%7BAUCTION_ID%7D"])
    }

    /// The host's own check of a fetched HTML or Native document: every upper-case `${…}` (and its percent-encoded form)
    /// left in it, in first-seen order; JavaScript template literals (`${width}`) and `[…]` are not OpenRTB macros there.
    @Test func unsubstitutedOpenRTBMacrosInAFetchedDocument() {
        let html = #"<img src="https://t.example/i?p=${AUCTION_PRICE}&cb=[CACHEBUSTING]&q=%24%7BAUCTION_ID%7D"><script>const w = `${width}px`; x(${AUCTION_PRICE:B64});</script>"#
        #expect(MacroExpander.unsubstitutedOpenRTBMacros(in: html) == ["${AUCTION_PRICE}", "%24%7BAUCTION_ID%7D", "${AUCTION_PRICE:B64}"])
        let native = #"{"native":{"imptrackers":["https://t.example/i?p=${AUCTION_PRICE}"],"link":{"url":"https://l.example/?b=${AUCTION_BID_ID}"}}}"#
        #expect(MacroExpander.unsubstitutedOpenRTBMacros(in: native) == ["${AUCTION_PRICE}", "${AUCTION_BID_ID}"])
        #expect(MacroExpander.unsubstitutedOpenRTBMacros(in: "<p>no macros [CACHEBUSTING]</p>").isEmpty)
    }

    // MARK: - The matrix: origin × family

    /// Bid response URLs (nurl here; burl, lurl, AdCOM events and the banner link likewise): the exchange's `${…}` only.
    @Test func bidResponseURLs() {
        var candidate = AdCandidate(id: "0.0", bidID: "b", price: 2, format: .banner, markup: .html("<p/>"), winURL: Self.template)
        candidate.adcomEvents = [AdcomEvent(type: 2, method: 1, url: Self.template)]
        for event: AdLifecycleEvent in [.won, .rendered] {
            let requests = TrackingPlan.requests(for: event, candidate: candidate, native: nil, vast: nil, context: Self.context)
            #expect(requests.map(\.url) == ["https://t.example/px?p=1.23&cb=[CACHEBUSTING]&e=[ERRORCODE]"], "\(event)")
            #expect(requests.map(\.unknownMacros) == [["[CACHEBUSTING]", "[ERRORCODE]"]], "\(event)")
        }
    }

    /// Inline `adm` VAST: the exchange substituted `${…}` before the player saw it; the player expands `[…]`. No warning.
    @Test func inlineAdmVAST() async {
        let vast = await VASTResolver(fetcher: FakeVASTFetcher()).resolve(.xml(Self.exchangeSubstituted(Self.inlineVAST)))
        #expect(Self.errorURLs(vast) == ["https://t.example/px?p=1.23&cb=12345678&e=403"])
        #expect(Self.errorUnknowns(vast) == [[]])
        #expect(Self.unsubstitutedIssues(vast).isEmpty)
    }

    /// Inline `adm` that still carries `${…}` (an unknown exchange macro): literal, reported, but no document warning —
    /// the host's `adm` substitution already reports it.
    @Test func inlineAdmVASTNeverWarnsAboutItsOwnMacros() async {
        let vast = await VASTResolver(fetcher: FakeVASTFetcher()).resolve(.xml(Self.inlineVAST))
        #expect(Self.errorURLs(vast) == ["https://t.example/px?p=${AUCTION_PRICE}&cb=12345678&e=403"])
        #expect(Self.unsubstitutedIssues(vast).isEmpty)
    }

    /// VAST delivered by the win notice (`.xml` with the nurl request as parent): never substituted by the exchange.
    @Test func winNoticeDeliveredVAST() async throws {
        let vast = await VASTResolver(fetcher: FakeVASTFetcher()).resolve(.xml(Self.inlineVAST), parentRequestID: UUID())
        #expect(Self.errorURLs(vast) == ["https://t.example/px?p=${AUCTION_PRICE}&cb=12345678&e=403"])
        #expect(Self.errorUnknowns(vast) == [["${AUCTION_PRICE}"]])
        let issue = try #require(Self.unsubstitutedIssues(vast).first)
        #expect(Self.unsubstitutedIssues(vast).count == 1)
        #expect(issue.severity == .warning)
        #expect(issue.path == "VAST/Ad[1]/InLine/Error[1]")
        #expect(issue.message.contains("${AUCTION_PRICE}"))
    }

    /// VAST delivered by AdCOM `curl` or a pasted VAST tag URL (`.url`): the same.
    @Test func curlAndPastedTagDeliveredVAST() async throws {
        for tag in ["https://vast.example/curl", "https://vast.example/pasted-tag"] {
            let fetcher = FakeVASTFetcher([tag: .body(Self.inlineVAST)])
            let vast = await VASTResolver(fetcher: fetcher).resolve(.url(tag))
            #expect(Self.errorURLs(vast) == ["https://t.example/px?p=${AUCTION_PRICE}&cb=12345678&e=403"], "\(tag)")
            #expect(Self.errorUnknowns(vast) == [["${AUCTION_PRICE}"]], "\(tag)")
            #expect(Self.unsubstitutedIssues(vast).map(\.path) == ["VAST/Ad[1]/InLine/Error[1]"], "\(tag)")
        }
    }

    /// A wrapper hop: the inline `adm` wrapper was substituted by the exchange; the document its VASTAdTagURI served was
    /// not. Each URL keeps the expansion of its own document; the warning names the hop.
    @Test func wrapperServedVAST() async throws {
        let fetcher = FakeVASTFetcher(["https://vast.example/inner": .body(Self.inlineVAST)])
        let wrapper = Self.exchangeSubstituted(Self.wrapperVAST(adTagURI: "https://vast.example/inner"))
        let vast = await VASTResolver(fetcher: fetcher).resolve(.xml(wrapper))
        #expect(Self.errorURLs(vast) == ["https://t.example/px?p=1.23&cb=12345678&e=403&k=w",
                                         "https://t.example/px?p=${AUCTION_PRICE}&cb=12345678&e=403"])
        #expect(Self.errorUnknowns(vast) == [[], ["${AUCTION_PRICE}"]])
        let issues = Self.unsubstitutedIssues(vast)
        #expect(issues.map(\.path) == ["hop 1 › VAST/Ad[1]/InLine/Error[1]"])
        #expect(issues.first?.message.lowercased().contains("unsubstituted openrtb macro in a wrapper-served document") == true)
    }

    /// Native from inline `adm`: substituted by the exchange beforehand; the SDK fires its trackers as written.
    @Test func inlineAdmNative() throws {
        let json = #"{"native":{"ver":"1.2","assets":[{"id":1,"title":{"text":"T"}}],"link":{"url":"https://l.example/","clicktrackers":["\#(Self.template)&k=c"]},"imptrackers":["\#(Self.template)"]}}"#
        let substituted = Self.exchangeSubstituted(json)
        let native = try #require(NativeParser.parse(substituted).ad)
        let candidate = AdCandidate(id: "0.0", bidID: "n", price: 2, format: .native, markup: .native(substituted))
        let impressions = TrackingPlan.requests(for: .rendered, candidate: candidate, native: native, vast: nil, context: Self.context)
        #expect(impressions.map(\.url) == ["https://t.example/px?p=1.23&cb=[CACHEBUSTING]&e=[ERRORCODE]"])
        #expect(impressions.map(\.unknownMacros) == [["[CACHEBUSTING]", "[ERRORCODE]"]])
        let click = TrackingPlan.requests(for: .click(assetID: nil), candidate: candidate, native: native, vast: nil, context: Self.context)
        #expect(click.map(\.url) == ["https://t.example/px?p=1.23&cb=[CACHEBUSTING]&e=[ERRORCODE]&k=c", "https://l.example/"])
    }

    /// Native delivered by the win notice or `curl`: nobody substituted it, and the SDK expands nothing.
    @Test func deliveredNative() throws {
        let json = #"{"native":{"ver":"1.2","assets":[{"id":1,"title":{"text":"T"}}],"link":{"url":"https://l.example/?p=${AUCTION_PRICE}"},"imptrackers":["\#(Self.template)"],"jstracker":"<script src=\"https://t.example/j.js?p=${AUCTION_PRICE}\"></script>"}}"#
        let native = try #require(NativeParser.parse(json).ad)
        let candidate = AdCandidate(id: "0.0", bidID: "n", price: 2, format: .native, markup: .native(json), winURL: "https://dsp.example/win")
        let options = TrackingPlan.Options(markupRequestID: UUID())
        let impressions = TrackingPlan.requests(for: .rendered, candidate: candidate, native: native, vast: nil, context: Self.context,
                                                options: options)
        #expect(impressions.map(\.url) == [Self.template, #"<script src="https://t.example/j.js?p=${AUCTION_PRICE}"></script>"#])
        #expect(impressions.map(\.unknownMacros) == [["${AUCTION_PRICE}", "[CACHEBUSTING]", "[ERRORCODE]"], ["${AUCTION_PRICE}"]])
        let click = TrackingPlan.requests(for: .click(assetID: nil), candidate: candidate, native: native, vast: nil, context: Self.context,
                                          options: options)
        #expect(click.map(\.url) == ["https://l.example/?p=${AUCTION_PRICE}"])
        #expect(click.map(\.unknownMacros) == [["${AUCTION_PRICE}"]])
    }
}
