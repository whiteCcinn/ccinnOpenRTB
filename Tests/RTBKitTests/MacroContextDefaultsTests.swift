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
