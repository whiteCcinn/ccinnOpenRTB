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
}
