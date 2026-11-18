import Testing
@testable import RTBKit

@Suite("MacroContext.simulatorDefaults")
struct MacroContextDefaultsTests {
    private let phone = DeviceProfile(id: "p", name: "Phone", family: .iPhone, screenWidth: 393, screenHeight: 852, scale: 3, os: "iOS",
                                      osVersion: "18", make: "Apple", model: "iPhone", userAgent: "UA", openRTBDeviceType: 4)
    private let bid = AdCandidate(id: "0.0", bidID: "bid-1", impID: "imp-1", seat: "seat-1", price: 1.5, format: .banner, markup: .none)

    /// OpenRTB 2.x §4.4: `${AUCTION_BID_ID}` is `BidResponse.bidid`, not `Bid.id`.
    @Test func auctionBidIDIsTheResponseLevelBidID() {
        let context = MacroContext.simulatorDefaults(candidate: bid, request: nil, device: phone, responseBidID: "resp-bidid")
        #expect(context.bidID == "resp-bidid")
    }

    @Test func auctionBidIDFallsBackToTheBidIDWhenTheResponseHasNoBidID() {
        #expect(MacroContext.simulatorDefaults(candidate: bid, request: nil, device: phone).bidID == "bid-1")
        #expect(MacroContext.simulatorDefaults(candidate: bid, request: nil, device: phone, responseBidID: "").bidID == "bid-1")
    }

    /// `BidResponse.id` is "ID of the bid request to which this is a response", so it stands in for `${AUCTION_ID}` when no
    /// request was pasted; a pasted request wins.
    @Test func auctionIDFallsBackToTheResponseID() {
        #expect(MacroContext.simulatorDefaults(candidate: bid, request: nil, device: phone, responseID: "req-9").auctionID == "req-9")
        let request = BidRequestSummary(id: "req-1", impressions: [])
        #expect(MacroContext.simulatorDefaults(candidate: bid, request: request, device: phone, responseID: "req-9").auctionID == "req-1")
        #expect(MacroContext.simulatorDefaults(candidate: bid, request: nil, device: phone).auctionID == nil)
    }

    @Test func auctionValuesComeFromTheBid() {
        var candidate = bid
        candidate.adID = "ad-7"
        candidate.currency = "EUR"
        let context = MacroContext.simulatorDefaults(candidate: candidate, request: nil, device: phone)
        #expect(context.impID == "imp-1")
        #expect(context.seatID == "seat-1")
        #expect(context.adID == "ad-7")
        #expect(context.price == 1.5)
        #expect(context.currency == "EUR")
        #expect(context.device == phone)
    }

    /// `${AUCTION_MBR}` is clearing price / bid price; the default clearing price is the bid price.
    @Test func marketBidRatioIsOneAtTheDefaultClearingPrice() {
        #expect(MacroContext.simulatorDefaults(candidate: bid, request: nil, device: phone).marketBidRatio == 1)
        var free = bid
        free.price = 0
        #expect(MacroContext.simulatorDefaults(candidate: free, request: nil, device: phone).marketBidRatio == nil)
    }

    @Test func requestDerivedVASTValuesUseBracketedKeys() {
        let request = BidRequestSummary(id: "r", impressions: [], domain: "news.example", pageURL: "https://news.example/a", appBundle: "com.pub.app",
                                        ifa: "IFA-1", limitAdTracking: true, transactionID: "tx-1")
        let custom = MacroContext.simulatorDefaults(candidate: bid, request: request, device: phone).custom
        #expect(custom == ["[DOMAIN]": "news.example", "[PAGEURL]": "https://news.example/a", "[APPBUNDLE]": "com.pub.app", "[IFA]": "IFA-1",
                           "[LIMITADTRACKING]": "1", "[TRANSACTIONID]": "tx-1"])
    }

    /// decisions.md "Request facts for the remaining macros": typed request facts become VAST macros only here.
    @Test func requestFactsMapToTheirVASTMacros() {
        let request = BidRequestSummary(id: "r", impressions: [], deviceIP: "192.0.2.1", deviceUserAgent: "Request UA", latitude: 51.004703,
                                        longitude: -3.754806, ifaType: "rida", gdprConsent: "CONSENT", blockedCategories: ["IAB1-6", "IAB1-7"],
                                        contentID: "ep-1", contentURL: "https://media.example/ep1.mp4", storeURL: "https://apps.example/pub")
        let context = MacroContext.simulatorDefaults(candidate: bid, request: request, device: phone)
        #expect(context.custom["[DEVICEIP]"] == "192.0.2.1")
        #expect(context.custom["[DEVICEUA]"] == "Request UA")
        #expect(context.custom["[IFATYPE]"] == "rida")
        #expect(context.custom["[GDPRCONSENT]"] == "CONSENT")
        #expect(context.custom["[CONTENTID]"] == "ep-1")
        #expect(context.custom["[CONTENTURI]"] == "https://media.example/ep1.mp4")
        #expect(context.custom["[STOREURL]"] == "https://apps.example/pub")
        #expect(context.customLists["[LATLONG]"] == ["51.004703", "-3.754806"])
        #expect(context.customLists["[BLOCKEDADCATEGORIES]"] == ["IAB1-6", "IAB1-7"])
        #expect(MacroExpander.expand("ll=[LATLONG]&b=[BLOCKEDADCATEGORIES]&ua=[DEVICEUA]", context: context).url
            == "ll=51.004703,-3.754806&b=IAB1-6,IAB1-7&ua=Request%20UA")
    }

    @Test func absentFactsLeaveTheirMacrosUnknown() {
        let context = MacroContext.simulatorDefaults(candidate: bid, request: BidRequestSummary(id: "r", impressions: []), device: phone)
        #expect(context.customLists["[LATLONG]"] == nil)
        #expect(context.customLists["[BLOCKEDADCATEGORIES]"] == nil)
        #expect(MacroExpander.expand("[LATLONG]|[DEVICEIP]|[GDPRCONSENT]|[DEVICEUA]", context: context).url == "-1|-1|-1|UA")
    }

    /// The simulator's player plays VAST 2.0–4.2 (AdCOM Creative Subtypes), listed as an Array<integer>.
    @Test func supportedVASTVersionsAreAList() {
        let context = MacroContext.simulatorDefaults(candidate: bid, request: nil, device: phone)
        #expect(context.customLists["[VASTVERSIONS]"] == ["2", "3", "5", "6", "7", "8", "11", "12", "13", "14"])
    }

    /// `${AUCTION_MULTIPLIER}` (2.6 imp.qty.multiplier) and `${OPENRTB_ITEM_QTY}` (3.0 item.qty) of the impression the bid won.
    @Test func quantityMacrosComeFromTheMatchingImpression() {
        let request = BidRequestSummary(id: "r", impressions: [
            BidRequestSummary.Impression(id: "other", formats: [.banner], quantityMultiplier: 9, itemQuantity: 9),
            BidRequestSummary.Impression(id: "imp-1", formats: [.banner], quantityMultiplier: 2.5, itemQuantity: 3),
        ])
        let context = MacroContext.simulatorDefaults(candidate: bid, request: request, device: phone)
        #expect(MacroExpander.expandOpenRTB("${AUCTION_MULTIPLIER}|${OPENRTB_ITEM_QTY}", context: context).url == "2.5|3")
        let none = MacroContext.simulatorDefaults(candidate: bid, request: BidRequestSummary(id: "r", impressions: []), device: phone)
        #expect(MacroExpander.expandOpenRTB("${AUCTION_MULTIPLIER}|${OPENRTB_ITEM_QTY}", context: none).url == "|")
    }

    /// `${OPENRTB_ITEM_QTY}` is "from `item.qty` or `item.qtyflt`" (OpenRTB 3.0 §4.4 Substitution Macros): a whole quantity
    /// reads as the integer `qty` would (no trailing ".0"), a fractional one keeps its digits.
    @Test(arguments: [(3.0, "3"), (14.2, "14.2"), (0.5, "0.5"), (1_000_000, "1000000")])
    func itemQuantityMacroHasNoTrailingZero(quantity: Double, expected: String) {
        let request = BidRequestSummary(id: "r", impressions: [BidRequestSummary.Impression(id: "imp-1", formats: [.banner], itemQuantity: quantity)])
        let context = MacroContext.simulatorDefaults(candidate: bid, request: request, device: phone)
        #expect(MacroExpander.expandOpenRTB("${OPENRTB_ITEM_QTY}", context: context).url == expected)
    }

    /// VAST `[APPBUNDLE]` is the publisher app the ad runs in; `Bid.bundle` is the advertised app, so it never stands in.
    @Test func appBundleNeverComesFromTheAdvertisedApp() {
        var installAd = bid
        installAd.bundle = "com.advertiser.game"
        #expect(MacroContext.simulatorDefaults(candidate: installAd, request: nil, device: phone).custom["[APPBUNDLE]"] == nil)
    }

    /// OpenRTB 3.0 `bid.macro` keys are plain custom keys, referenced as `${CUSTOM_<KEY>}`.
    @Test func buyerMacrosExpandAsCustomPrefixedMacros() {
        var candidate = bid
        candidate.customMacros = ["CLICKTOKEN": "A7D800F2716DB"]
        let context = MacroContext.simulatorDefaults(candidate: candidate, request: nil, device: phone)
        #expect(MacroExpander.expandOpenRTB("https://t.example/c?tok=${CUSTOM_CLICKTOKEN}", context: context).url
            == "https://t.example/c?tok=A7D800F2716DB")
    }

    /// `[PLAYERSIZE]` defaults to the bid's size when the host has no player size yet; the host's value wins.
    @Test func playerSizeDefaultsToTheBidSize() {
        var video = bid
        video.size = AdSize(width: 640, height: 360)
        let fallback = MacroContext.simulatorDefaults(candidate: video, request: nil, device: phone)
        #expect(fallback.playerWidth == 640)
        #expect(fallback.playerHeight == 360)
        let explicit = MacroContext.simulatorDefaults(candidate: video, request: nil, device: phone, playerWidth: 393, playerHeight: 221)
        #expect(explicit.playerWidth == 393)
        #expect(explicit.playerHeight == 221)
    }
}
