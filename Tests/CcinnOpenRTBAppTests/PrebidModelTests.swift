import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

private let registry = #"""
{"name":"prebid.js","time":{"created":"2016-01-01T00:00:00.000Z","modified":"2026-11-18T00:00:00.000Z",
 "1.0.0":"2026-10-01T00:00:00.000Z","1.1.0":"2026-11-18T00:00:00.000Z"}}
"""#
private let metadata = #"{"fakeBidAdapter":{"components":[{"componentType":"bidder","componentName":"fake","gvlid":7}]},"appnexusBidAdapter":{"components":[{"componentType":"bidder","componentName":"appnexus","gvlid":32}]}}"#
private let bundle = #"""
window.pbjs = window.pbjs || { que: [] };
(function () {
  var units = [], handlers = {};
  pbjs.version = 'v1.0.0';
  pbjs.setConfig = function () {};
  pbjs.addAdUnits = function (u) { units = units.concat(u); };
  pbjs.onEvent = function (name, f) { (handlers[name] = handlers[name] || []).push(f); };
  function emit(name, data) { (handlers[name] || []).forEach(function (f) { f(data); }); }
  pbjs.requestBids = function (options) {
    emit('auctionInit', {});
    emit('bidRequested', { bidderCode: 'fake', bids: [{ adUnitCode: units[0].code }] });
    console.warn('Invalid bid sent to bidder appnexus: {"placementId":"x"}');
    fetch('https://bidder.test/bid', { method: 'POST', body: '{}' }).then(function (r) { return r.json(); }).then(function (j) {
      var bid = { bidderCode: 'fake', adId: 'a1', adUnitCode: units[0].code, cpm: j.cpm, currency: 'USD', width: 300, height: 250, mediaType: 'banner', ad: j.ad };
      emit('bidResponse', bid);
      emit('noBid', { bidder: 'appnexus', adUnitCode: units[0].code });
      emit('auctionEnd', {});
      var responses = {}; responses[units[0].code] = { bids: [bid] };
      options.bidsBackHandler(responses);
      new Image().src = 'https://sync.dsp.example/pixel?redir=x';
    });
  };
  var queue = pbjs.que; pbjs.que = { push: function (f) { f(); } }; queue.forEach(function (f) { f(); });
})();
"""#

@MainActor
@Suite("Prebid: model", .serialized)
struct PrebidModelTests {
    @MainActor
    private struct Harness {
        let transport = ScriptedTransport()
        let monitor: NetworkMonitor
        let target: RecordingSimulatorTarget
        let cache = TemporaryDirectory()
        let model: PrebidModel

        init() {
            monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
            target = RecordingSimulatorTarget(monitor: monitor)
            let monitor = monitor
            let library = PrebidLibrary(cacheDirectory: cache.url, upstreamBase: "https://cdn.test/npm/prebid.js@", registry: "https://registry.test/prebid.js",
                                        monitor: { monitor }, userAgent: { "UA" })
            model = PrebidModel(target: target, library: library, now: { Date(timeIntervalSince1970: 1_795_000_000) }) // 2026-11-19
            transport.answer("https://registry.test/prebid.js", .init(body: registry))
            transport.answer("https://cdn.test/npm/prebid.js@1.0.0/metadata/modules.json", .init(body: metadata))
            transport.answer("https://cdn.test/npm/prebid.js@1.0.0/dist/bundle.js", .init(headers: ["Content-Type": "application/javascript"], body: bundle))
            transport.answer("https://bidder.test/bid", .init(headers: ["Content-Type": "application/json", "Access-Control-Allow-Origin": "*"],
                                                              body: #"{"cpm":1.75,"ad":"<div>${AUCTION_PRICE}</div>"}"#))
        }
    }

    /// The versions, the default (newest at least two weeks old) and its bidders.
    @Test func preparingPicksTheDefaultVersionAndItsBidders() async throws {
        let harness = Harness()
        defer { harness.cache.cleanUp() }

        await harness.model.prepare()

        #expect(harness.model.versions == ["1.1.0", "1.0.0"])
        #expect(harness.model.defaultVersion == "1.0.0")
        #expect(harness.model.setup.version == "1.0.0")
        #expect(harness.model.catalog.keys.sorted() == ["appnexus", "fake"])
        #expect(harness.model.setup.adUnits.first?.bids.first?.bidder == "appnexus", "a working ad unit to start from")
    }

    @Test func anAuctionReportsItsBidsTimelineSyncsAndWarnings() async throws {
        let harness = Harness()
        defer { harness.cache.cleanUp() }
        let window = WindowHarness(PrebidWebView(host: harness.model.host), size: CGSize(width: 360, height: 200))
        defer { window.close() }
        await harness.model.prepare()
        harness.model.setup.adUnits[0].bids = [PrebidBidderParams(bidder: "fake", params: "{}")]

        harness.model.runAuction()
        let ended = await Wait.until(timeout: .seconds(20)) { harness.model.phase == .done }
        #expect(ended, "\(harness.model.phase) \(harness.model.timeline.map(\.type))")

        #expect(harness.model.bids.map(\.cpm) == [1.75])
        let types = harness.model.timeline.map(\.type)
        #expect(types.contains("bidRequested") && types.contains("bidResponse") && types.contains("noBid") && types.contains("auctionEnd"))
        #expect(harness.model.timeline.contains { $0.type == "noBid" && $0.summary.contains("appnexus") })
        #expect(harness.model.syncs == [PrebidModel.Sync(kind: "image", url: "https://sync.dsp.example/pixel?redir=x")])
        #expect(harness.model.warnings.contains { $0.contains("Invalid bid sent to bidder appnexus") })
        #expect(harness.model.loadedVersion == "v1.0.0")

        // Shown on the device by the simulator's own path.
        await harness.model.render(try #require(harness.model.bids.first))
        let load = try #require(harness.target.loads.first)
        #expect(load.rendering == .always)
        let parsed = InputParser.parse(load.response)
        #expect(parsed.candidates.first?.markup == .html("<div>1.75</div>"))
        #expect(parsed.candidates.first?.seat == "fake")
    }

    @Test func problemsStopTheAuctionBeforeItStarts() async throws {
        let harness = Harness()
        defer { harness.cache.cleanUp() }
        await harness.model.prepare()
        harness.model.setup.adUnits[0].bids[0].params = "not json"

        harness.model.runAuction()

        guard case let .failed(message) = harness.model.phase else { Issue.record("\(harness.model.phase)"); return }
        #expect(message.contains("not a JSON object"))
        #expect(!harness.transport.requests.contains { $0.url.absoluteString.contains("bundle.js") })
    }

    /// A sync the adapters asked for goes to the Sync tab to be run there, with its cookie jar.
    @Test func aSyncIsHandedToTheSyncTab() throws {
        let harness = Harness()
        defer { harness.cache.cleanUp() }
        let sync = SyncModel(target: SyncRecordingTarget(monitor: harness.monitor))
        harness.model.syncModel = sync
        harness.model.setup.pageURL = "https://sports.example/live"
        harness.model.useInSyncTab(PrebidModel.Sync(kind: "image", url: "https://sync.dsp.example/pixel?x=1"))
        #expect(sync.startURL == "https://sync.dsp.example/pixel?x=1")
        #expect(sync.publisherURL == "https://sports.example/live", "the sync fired on the Prebid page: its site decides what is third party")
    }

    /// Choosing a version loads its bidders; a slower answer for a version no longer chosen never replaces them.
    @Test func theChosenVersionsBiddersWin() async throws {
        let harness = Harness()
        defer { harness.cache.cleanUp() }
        await harness.model.prepare()
        harness.transport.answer("https://cdn.test/npm/prebid.js@1.1.0/metadata/modules.json",
                                 .init(body: #"{"newBidAdapter":{"components":[{"componentType":"bidder","componentName":"newcomer"}]}}"#, delay: .milliseconds(400)))

        harness.model.choose(version: "1.1.0")
        #expect(harness.model.phase == .preparing)
        harness.model.choose(version: "1.0.0")
        let settled = await Wait.until(timeout: .seconds(5)) { harness.model.phase == .idle }
        #expect(settled)
        try await Task.sleep(for: .milliseconds(600))

        #expect(harness.model.setup.version == "1.0.0")
        #expect(harness.model.catalog.keys.sorted() == ["appnexus", "fake"])
        #expect(harness.model.phase == .idle)
    }

    /// A new version mid-auction stops the auction: its events belong to the old page.
    @Test func choosingAVersionStopsARunningAuction() async throws {
        let harness = Harness()
        defer { harness.cache.cleanUp() }
        await harness.model.prepare()
        harness.transport.answer("https://bidder.test/bid", .init(body: #"{"cpm":1,"ad":"<div/>"}"#, delay: .seconds(30)))
        harness.model.setup.adUnits[0].bids = [PrebidBidderParams(bidder: "fake", params: "{}")]
        harness.model.runAuction()
        #expect(harness.model.phase == .running)

        harness.model.choose(version: "1.1.0")

        #expect(harness.model.phase == .preparing)
        harness.model.handle(type: "bidsBack", payload: #"[{"bidderCode":"fake","adId":"a","cpm":1,"ad":"<div/>"}]"#)
        #expect(harness.model.bids.isEmpty, "the stopped page's events are ignored")
    }
}

@MainActor
private final class SyncRecordingTarget: SyncTargetProviding {
    let monitor: NetworkMonitor
    let device = DeviceCatalog.defaultDevice
    init(monitor: NetworkMonitor) { self.monitor = monitor }
}
