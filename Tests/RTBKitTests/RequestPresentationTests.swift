import Foundation
import Testing
@testable import RTBKit

/// The bid request's ad unit (bid-client B6): whether an impression is shown full screen (interstitial) and whether it is
/// rewarded, from the spec fields and the extensions real exchanges still send.
@Suite("InputParser – impression presentation")
struct RequestPresentationTests {
    private func impression(_ imp: String) throws -> BidRequestSummary.Impression {
        let request = #"{"id":"r","imp":["# + imp + "]}"
        let summary = try #require(InputParser.parse(OpenRTBFixtures.spec25WinNotice, request: request).request)
        return try #require(summary.impressions.first)
    }

    private func item(_ item: String) throws -> BidRequestSummary.Impression {
        let request = #"{"openrtb":{"ver":"3.0","request":{"id":"r","item":["# + item + "]}}}"
        let summary = try #require(InputParser.parse(OpenRTBFixtures.spec30Banner, request: request).request)
        return try #require(summary.impressions.first)
    }

    @Test func aPlainImpressionIsNeitherInterstitialNorRewarded() throws {
        let plain = try impression(#"{"id":"1","banner":{"w":320,"h":50},"instl":0,"rwdd":0}"#)
        #expect(!plain.isInterstitial)
        #expect(!plain.isRewarded)
    }

    /// OpenRTB 2.x `imp.instl` ("1 = the ad is interstitial or full screen").
    @Test func instlMakesAnInterstitial() throws {
        let imp = try impression(#"{"id":"1","banner":{"w":320,"h":50},"instl":1}"#)
        #expect(imp.isInterstitial)
        #expect(!imp.isRewarded)
    }

    /// OpenRTB 2.6 `imp.rwdd` ("1 = the user receives a reward for viewing the creative").
    @Test func rwddMakesARewardedImpression() throws {
        let imp = try impression(#"{"id":"1","video":{"w":640,"h":360},"instl":1,"rwdd":1}"#)
        #expect(imp.isRewarded)
        #expect(imp.isInterstitial)
    }

    /// OpenRTB 2.6 `video.plcmt` 3 is "Interstitial".
    @Test func videoPlcmtThreeIsAnInterstitial() throws {
        #expect(try impression(#"{"id":"1","video":{"w":640,"h":360,"plcmt":3}}"#).isInterstitial)
        #expect(!(try impression(#"{"id":"1","video":{"w":640,"h":360,"plcmt":1}}"#).isInterstitial))
    }

    /// Pre-2.6 requests carry the reward in an extension: Google's `imp.ext.is_rewarded_inventory` (a boolean) and Prebid's
    /// `imp.ext.prebid.is_rewarded_inventory` (an integer). Extensions are not validated: no issue either way.
    @Test(arguments: [#"{"is_rewarded_inventory":true}"#, #"{"is_rewarded_inventory":1}"#, #"{"prebid":{"is_rewarded_inventory":1}}"#])
    func rewardedExtensionsAreRead(ext: String) throws {
        let request = #"{"id":"r","imp":[{"id":"1","video":{"w":640,"h":360},"ext":"# + ext + "}]}"
        let input = InputParser.parse(OpenRTBFixtures.spec25WinNotice, request: request)
        #expect(try #require(input.request?.impressions.first).isRewarded)
        #expect(!input.issues.contains { $0.path.contains("is_rewarded_inventory") })
    }

    @Test func aFalseRewardedExtensionIsNotRewarded() throws {
        #expect(!(try impression(#"{"id":"1","video":{"w":640,"h":360},"ext":{"is_rewarded_inventory":false,"prebid":{"is_rewarded_inventory":0}}}"#).isRewarded))
    }

    /// AdCOM 1.0 `DisplayPlacement.instl` and `Placement.reward`.
    @Test func adcomInstlAndReward() throws {
        let interstitial = try item(#"{"id":"1","spec":{"placement":{"display":{"w":320,"h":480,"instl":1}}}}"#)
        #expect(interstitial.isInterstitial)
        #expect(!interstitial.isRewarded)
        let rewarded = try item(#"{"id":"1","spec":{"placement":{"reward":1,"video":{"w":1280,"h":720}}}}"#)
        #expect(rewarded.isRewarded)
        #expect(!rewarded.isInterstitial)
    }
}

@Suite("Tracker categories")
struct TrackerCategoryTests {
    /// A bid request the user sends from the Client tab is not a tracker: Simulated mode does not hold it back.
    @Test func aBidRequestIsNotATracker() {
        #expect(!TrackerCategory.bidRequest.isTracker)
        #expect(TrackerCategory.bidRequest.rawValue == "bidRequest")
        #expect(TrackerCategory.allCases.contains(.bidRequest))
    }
}
