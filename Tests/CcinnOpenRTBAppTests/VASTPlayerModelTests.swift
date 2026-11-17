import CoreGraphics
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// The player's lifecycle reporting (decisions.md): per pod ad i `.video(.loaded, i)` → at the first frame of the first
/// ad `.rendered` → `.video(.creativeView, i)` → `.video(.start, i)` → quartiles / progress → `complete` / `skip`.
@MainActor
@Suite("VAST player model")
struct VASTPlayerModelTests {
    private static let playEverything: VASTMediaChooser = { files, _, _, _ in
        files.first.map(VASTMediaSelector.Choice.play) ?? .unsupported(.noSupportedMedia)
    }

    private func make(_ ads: [ResolvedVASTAd], device: DeviceProfile = RendererFixtures.phone, placement: Placement = .interstitial,
                      reportsRendered: Bool = true, choose: @escaping VASTMediaChooser = playEverything,
                      readyTimeout: Duration = .seconds(30)) -> (VASTPlayerModel, RecordingHost, FakeEngine) {
        let host = RecordingHost(device: device)
        let engine = FakeEngine()
        var configuration = VASTPlayerConfiguration(placement: placement, device: device, playerSize: CGSize(width: 390, height: 219),
                                                    audioOnly: false, source: "bid 0.0 › VAST")
        configuration.reportsRendered = reportsRendered
        configuration.readyTimeout = readyTimeout
        let model = VASTPlayerModel(vast: ResolvedVAST(ads: ads), configuration: configuration, host: host, engine: engine, chooseMedia: choose)
        return (model, host, engine)
    }

    private func waitForLoad(_ engine: FakeEngine, count: Int = 1) async {
        let loaded = await Wait.until { engine.loaded.count >= count }
        #expect(loaded, "media \(count) was never loaded")
    }

    @Test func aSingleAdReportsEveryEventOnceInOrder() async {
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 4)])
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 4))
        #expect(engine.isPlaying, "autoplay")
        engine.tick(from: 0, to: 4)
        engine.send(.ended)
        #expect(host.events == [.video(.loaded, adIndex: 0), .rendered, .video(.creativeView, adIndex: 0), .video(.start, adIndex: 0),
                                .video(.firstQuartile, adIndex: 0), .video(.midpoint, adIndex: 0), .video(.thirdQuartile, adIndex: 0),
                                .video(.complete, adIndex: 0)])
        #expect(await Wait.until { model.phase == .finished })
        // Remote media: the player reported the load outcome to the monitor.
        let media = host.monitor.liveEntries.first { $0.url == "https://cdn.example/a.mp4" }
        #expect(media?.state == .completed(status: 200))
        #expect(media?.delivery == .renderer)
        // Late engine noise after the end changes nothing.
        engine.tick(from: 3, to: 4)
        engine.send(.ended)
        #expect(host.events.count == 8)
    }

    @Test func podAdsPlayInOrderAndBillingFiresOnce() async {
        let first = RendererFixtures.linearAd(duration: 2, media: [.init(url: "https://cdn.example/1.mp4", type: "video/mp4")], sequence: 1)
        let second = RendererFixtures.linearAd(duration: 2, media: [.init(url: "https://cdn.example/2.mp4", type: "video/mp4")], sequence: 2)
        let (model, host, engine) = make([first, second], device: RendererFixtures.tv, placement: .ctvInstream)
        model.start()
        await waitForLoad(engine)
        #expect(model.adNumber == 1 && model.adCount == 2)
        engine.send(.ready(duration: 2))
        engine.tick(from: 0, to: 2)
        engine.send(.ended)
        await waitForLoad(engine, count: 2)
        #expect(engine.loaded.map(\.lastPathComponent) == ["1.mp4", "2.mp4"])
        #expect(model.adNumber == 2)
        engine.send(.ready(duration: 2))
        engine.tick(from: 0, to: 2)
        engine.send(.ended)
        #expect(host.events.filter { $0 == .rendered }.count == 1)
        let renderedIndex = host.events.firstIndex(of: .rendered)
        #expect(renderedIndex == host.events.firstIndex(of: .video(.creativeView, adIndex: 0)).map { $0 - 1 })
        #expect(host.videoEvents(adIndex: 0) == [.loaded, .creativeView, .start, .firstQuartile, .midpoint, .thirdQuartile, .complete])
        #expect(host.videoEvents(adIndex: 1) == [.loaded, .creativeView, .start, .firstQuartile, .midpoint, .thirdQuartile, .complete])
        let lastOfFirst = host.events.firstIndex(of: .video(.complete, adIndex: 0)) ?? .max
        let firstOfSecond = host.events.firstIndex(of: .video(.loaded, adIndex: 1)) ?? -1
        #expect(lastOfFirst < firstOfSecond)
    }

    @Test func unsupportedMediaIsAnErrorAndThePodMovesOn() async {
        let vpaid = RendererFixtures.linearAd(media: [.init(url: "https://cdn.example/v.js", type: "application/javascript", apiFramework: "VPAID")])
        let playable = RendererFixtures.linearAd(duration: 1)
        let (model, host, engine) = make([vpaid, playable]) { files, _, _, _ in
            files.first?.apiFramework == "VPAID" ? .unsupported(.vpaidError) : .play(files[0])
        }
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 1))
        engine.tick(from: 0, to: 0.2)
        #expect(Array(host.events.prefix(4)) == [.error(.vpaidError, adIndex: 0), .video(.loaded, adIndex: 1), .rendered,
                                                .video(.creativeView, adIndex: 1)],
                "billing fires at the first frame of the first ad that actually plays")
    }

    @Test func skippingEndsTheAdWithoutComplete() async {
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 20, skipOffset: .seconds(5))])
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 20))
        engine.tick(from: 0, to: 4)
        #expect(model.skipState == .countdown(1))
        model.skip()
        #expect(!host.videoEvents(adIndex: 0).contains(.skip), "not skippable yet")
        engine.tick(from: 4.1, to: 6)
        #expect(model.skipState == .available)
        model.skip()
        engine.send(.ended)
        #expect(host.videoEvents(adIndex: 0) == [.loaded, .creativeView, .start, .firstQuartile, .skip])
        #expect(await Wait.until { model.phase == .finished })
    }

    @Test func rewardedAdsCannotBeSkipped() async {
        // The model holds its host weakly (the session owns the view that owns the player): keep it alive.
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 20, skipOffset: .seconds(1))], placement: .rewarded)
        defer { withExtendedLifetime(host) {} }
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 20))
        engine.tick(from: 0, to: 3)
        #expect(model.skipState == .hidden)
    }

    @Test func pauseMuteAndPlaybackStatus() async {
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 10)])
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 10))
        engine.tick(from: 0, to: 1)
        model.togglePlayback()
        #expect(!engine.isPlaying)
        model.togglePlayback()
        model.toggleMute()
        model.toggleMute()
        #expect(host.videoEvents(adIndex: 0).suffix(4) == [.pause, .resume, .mute, .unmute])
        // About 4 Hz while playing (playhead steps of 0.25 s), plus every play / pause / mute change.
        let playingTicks = host.statuses.filter { $0.isPlaying && !$0.isMuted }
        #expect(playingTicks.count >= 4 && playingTicks.count <= 8)
        #expect(host.statuses.contains { !$0.isPlaying && $0.playhead >= 0.9 })
        #expect(host.statuses.contains { $0.isMuted })
        #expect(host.statuses.allSatisfy { $0.adIndex == 0 && $0.duration == 10 })
    }

    @Test func mediaFailureBeforeReadyIs401AndTheLoadIsFinished() async {
        let (model, host, engine) = make([RendererFixtures.linearAd()])
        model.start()
        await waitForLoad(engine)
        engine.send(.failed("cannot decode"))
        #expect(host.events == [.error(.fileNotFound, adIndex: 0)])
        #expect(await Wait.until { model.phase == .finished })
        let media = host.monitor.liveEntries.first { $0.url == "https://cdn.example/a.mp4" }
        #expect(media?.state == .failed("cannot decode"))
    }

    @Test func aMediaFileThatNeverBecomesReadyTimesOut() async {
        let (model, host, engine) = make([RendererFixtures.linearAd()], readyTimeout: .milliseconds(30))
        model.start()
        await waitForLoad(engine)
        let timedOut = await Wait.until { host.events.contains(.error(.mediaTimeout, adIndex: 0)) }
        #expect(timedOut)
        #expect(engine.stops >= 1)
        engine.send(.ready(duration: 15))
        #expect(!host.events.contains(.video(.loaded, adIndex: 0)), "a late ready of the abandoned media is ignored")
        _ = model
    }

    @Test func clickThroughReportsTheVideoClickAndLeavesTheNavigationToThePlan() async {
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 10)])
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 10))
        engine.tick(from: 0, to: 1)
        model.clickThrough()
        #expect(host.events.suffix(2) == [.videoClick(adIndex: 0), .video(.pause, adIndex: 0)])
        #expect(host.navigations.isEmpty, "the .videoClick tracking plan records the ClickThrough navigation")
    }

    @Test func ctvHasNoClickThrough() async {
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 10)], device: RendererFixtures.tv, placement: .ctvInstream)
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 10))
        engine.tick(from: 0, to: 1)
        #expect(!model.showsLearnMore)
        model.clickThrough()
        #expect(!host.events.contains(.videoClick(adIndex: 0)))
        #expect(host.navigations.isEmpty)
    }

    @Test func closingReportsCloseLinearThenClosed() async {
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 10), RendererFixtures.linearAd(duration: 10)])
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 10))
        engine.tick(from: 0, to: 1)
        model.close()
        #expect(host.events.suffix(2) == [.video(.closeLinear, adIndex: 0), .closed])
        #expect(model.phase == .closed)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(engine.loaded.count == 1, "the rest of the pod does not play")
    }

    @Test func teardownStopsSilently() async {
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 10)])
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 10))
        engine.tick(from: 0, to: 1)
        let count = host.events.count
        model.teardown()
        engine.tick(from: 1, to: 9)
        engine.send(.ended)
        #expect(host.events.count == count, "no tracking after teardown")
        #expect(engine.stops >= 1)
        #expect(host.statuses.last?.isPlaying == false, "the shell's viewability timers stop")
    }

    @Test func nestedPlayersDoNotReportBilling() async {
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 1)], placement: .inFeed, reportsRendered: false)
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 1))
        engine.tick(from: 0, to: 0.5)
        #expect(!host.events.contains(.rendered))
        #expect(host.videoEvents(adIndex: 0).prefix(3) == [.loaded, .creativeView, .start])
    }

    @Test func inlineVideoPausesWhenScrolledOutOfView() async {
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 10)], placement: .inFeed)
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 10))
        engine.tick(from: 0, to: 1)
        #expect(engine.muted == true, "in-feed video autoplays muted")
        model.setVisibleFraction(0.2)
        #expect(!engine.isPlaying)
        model.setVisibleFraction(0.3)
        model.setVisibleFraction(0.9)
        #expect(engine.isPlaying)
        #expect(host.videoEvents(adIndex: 0).suffix(2) == [.pause, .resume])
    }

    @Test func companionViewAndClickFireOncePerCompanion() async {
        let companion = VASTCompanion(id: "c", width: 300, height: 250,
                                      resources: [.staticResource(url: "https://c.example/c.png", creativeType: "image/png")],
                                      clickThrough: "https://adv.example/companion")
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 2, companions: [companion])])
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 2))
        engine.tick(from: 0, to: 0.5)
        let choice = CompanionChoice(companionIndex: 0, companion: companion, resource: .image(url: "https://c.example/c.png"))
        model.companionDidAppear(choice, adIndex: 0)
        model.companionDidAppear(choice, adIndex: 0)
        model.companionClicked(choice, adIndex: 0, url: nil)
        #expect(host.events.filter { $0 == .companionView(adIndex: 0, companionIndex: 0) }.count == 1)
        #expect(host.events.last == .companionClick(adIndex: 0, companionIndex: 0))
        #expect(host.navigations.isEmpty, "the .companionClick tracking plan records the CompanionClickThrough navigation")
        // The companion's own markup navigated elsewhere: that navigation is the player's to record.
        model.companionClicked(choice, adIndex: 0, url: "https://adv.example/other")
        #expect(host.navigations == [.init(url: "https://adv.example/other", trigger: "companion creative navigation")])
        model.companionClicked(choice, adIndex: 0, url: "https://adv.example/companion")
        #expect(host.navigations.count == 1, "the same URL as CompanionClickThrough is the plan's navigation")
    }
}
