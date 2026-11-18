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

    /// Spec review (blocker on 0864bf9): what the app fetches in Simulated mode must not carry the pasted request's personal
    /// values. The context for those fetches drops IFA, IFA type, device IP, lat/long, GDPR consent and the GPP string and
    /// section ids (they take the expander's unknown value, -1); `[DEVICEUA]` is the simulated device's User-Agent — the one
    /// the app sends. Everything else (cache buster, the publisher's domain, …) keeps working.
    @Test func theContextForSimulatedContentFetchesCarriesNoRequestIdentifiers() {
        let request = BidRequestSummary(id: "r", impressions: [], domain: "news.example", ifa: "REAL-USER-IFA-1234", deviceIP: "203.0.113.7",
                                        deviceUserAgent: "RealUA/1.0", latitude: 3.139, longitude: 101.6869, ifaType: "idfa",
                                        gdprConsent: "CPREALCONSENTSTRING", usPrivacy: "1YNN", gppString: "DBABMA~CPREALGPP", gppSectionIDs: [2, 6])
        let full = MacroContext.simulatorDefaults(candidate: bid, request: request, device: phone)
        let template = "ifa=[IFA]&t=[IFATYPE]&ip=[DEVICEIP]&ll=[LATLONG]&gdpr=[GDPRCONSENT]&gpp=[GPPSTRING]&sid=[GPPSECTIONID]&ua=[DEVICEUA]&d=[DOMAIN]"
        #expect(MacroExpander.expandVAST(template, context: full).url
            == "ifa=REAL-USER-IFA-1234&t=idfa&ip=203.0.113.7&ll=3.139,101.6869&gdpr=CPREALCONSENTSTRING&gpp=DBABMA~CPREALGPP&sid=2,6&ua=RealUA%2F1.0&d=news.example",
                "Real mode: the request's values (unchanged)")
        let safe = full.withoutRequestIdentifiers()
        let expanded = MacroExpander.expandVAST(template + "&cb=[CACHEBUSTING]", context: safe).url
        #expect(expanded.hasPrefix("ifa=-1&t=-1&ip=-1&ll=-1&gdpr=-1&gpp=-1&sid=-1&ua=UA&d=news.example&cb="), "\(expanded)")
        for secret in ["REAL-USER-IFA-1234", "203.0.113.7", "3.139", "101.6869", "CPREALCONSENTSTRING", "CPREALGPP", "RealUA", "idfa"] {
            #expect(!expanded.contains(secret), "\(secret) left the Mac: \(expanded)")
        }
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

    /// VAST 4.1/4.2 §6.11 "Regulation Info": `[REGULATIONS]` is an Array<string>, the "List of applicable regulations",
    /// whose possible values are `coppa` and `gdpr`. The list is complete only when both flags are given; with either
    /// one unknown it cannot be told, so the macro stays unknown (-1). Both 0 is a known, empty list.
    @Test(arguments: [
        (Optional(true), Optional(true), "coppa,gdpr"), (false, true, "gdpr"), (true, false, "coppa"), (false, false, ""),
        (nil, true, "-1"), (true, nil, "-1"), (nil, false, "-1"), (nil, nil, "-1"),
    ])
    func regulationsListOnlyWhenBothFlagsAreKnown(coppa: Bool?, gdpr: Bool?, expected: String) {
        let request = BidRequestSummary(id: "r", impressions: [], gdprApplies: gdpr, coppa: coppa)
        let context = MacroContext.simulatorDefaults(candidate: bid, request: request, device: phone)
        #expect(MacroExpander.expand("[REGULATIONS]", context: context).url == expected)
    }

    /// `[GPPSTRING]` (string) and `[GPPSECTIONID]` (Array<integer>) are in the IAB VAST macro list, which VAST 4.3 §6.2
    /// makes the reference ("Please reference the Macro list in GitHub"); the IAB examples are used here.
    @Test func gppMacrosComeFromRegs() {
        let request = BidRequestSummary(id: "r", impressions: [], gppString: "DBABMA~CPXxRfAPXxRfAAfKABENB-CgAAAAAAAAAAYgAAAAAAAA",
                                        gppSectionIDs: [5, 7])
        let context = MacroContext.simulatorDefaults(candidate: bid, request: request, device: phone)
        #expect(context.customLists["[GPPSECTIONID]"] == ["5", "7"])
        #expect(MacroExpander.expand("s=[GPPSTRING]&sid=[GPPSECTIONID]", context: context).url
            == "s=DBABMA~CPXxRfAPXxRfAAfKABENB-CgAAAAAAAAAAYgAAAAAAAA&sid=5,7")
        let none = MacroContext.simulatorDefaults(candidate: bid, request: BidRequestSummary(id: "r", impressions: []), device: phone)
        #expect(MacroExpander.expand("s=[GPPSTRING]&sid=[GPPSECTIONID]&r=[REGULATIONS]", context: none).url == "s=-1&sid=-1&r=-1")
    }

    /// No VAST 4.x or OpenRTB macro carries the US Privacy string: it stays a request fact.
    @Test func usPrivacyIsNotAMacro() {
        let request = BidRequestSummary(id: "r", impressions: [], usPrivacy: "1YNN")
        let context = MacroContext.simulatorDefaults(candidate: bid, request: request, device: phone)
        #expect(!context.custom.values.contains("1YNN"))
        #expect(!context.customLists.values.contains { $0.contains("1YNN") })
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
