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
    private let keepAlive = KeepAlive()

    private static let playEverything: VASTMediaChooser = { files, _, _, _ in
        files.first.map(VASTMediaSelector.Choice.play) ?? .unsupported(.noSupportedMedia)
    }

    private func make(_ ads: [ResolvedVASTAd], device: DeviceProfile = RendererFixtures.phone, placement: Placement = .interstitial,
                      reportsRendered: Bool = true, choose: @escaping VASTMediaChooser = playEverything,
                      readyTimeout: Duration = .seconds(30)) -> (VASTPlayerModel, RecordingHost, FakeEngine) {
        let host = keepAlive.hold(RecordingHost(device: device))
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
        #expect(media?.delivery == .network, "remote media is fetched by the monitor, not by AVPlayer")
        // Late engine noise after the end changes nothing.
        engine.tick(from: 3, to: 4)
        engine.send(.ended)
        #expect(host.events.count == 8)
    }

    /// The host reads `[ADPLAYHEAD]` from the last playback status, so the player reports the playhead before the events
    /// it crosses: a quartile or `progress` tracker carries the playhead it fired at, not one up to a status interval old.
    @Test func eventsCarryThePlayheadTheyFiredAt() async {
        let tracking = [VASTTracking(event: .progress(.seconds(5)), url: "https://t.example/p5")]
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 15, tracking: tracking)])
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 15))
        engine.tick(from: 0, to: 15, step: 0.1)
        engine.send(.ended)
        let fired = zip(host.events, host.playheadAtEvents)
        let expected: [(AdLifecycleEvent, Double)] = [(.video(.firstQuartile, adIndex: 0), 3.75), (.video(.progress(.seconds(5)), adIndex: 0), 5),
                                                      (.video(.midpoint, adIndex: 0), 7.5), (.video(.thirdQuartile, adIndex: 0), 11.25)]
        for (event, threshold) in expected {
            let playhead = fired.first { $0.0 == event }?.1 ?? nil
            #expect(playhead.map { $0 >= threshold - 1e-6 && $0 < threshold + 0.11 } == true, "\(event) fired with [ADPLAYHEAD] \(String(describing: playhead))")
        }
    }

    // MARK: CompanionAds@required

    private func requiringCompanions(_ requirement: VASTCompanionRequirement, _ companions: [VASTCompanion],
                                     media: String = "https://cdn.example/a.mp4") -> ResolvedVASTAd {
        var ad = RendererFixtures.linearAd(duration: 2, media: [VASTMediaFile(url: media, type: "video/mp4")], companions: companions)
        ad.inline.creatives[0].companionsRequired = requirement
        return ad
    }

    private static let htmlCompanion = VASTCompanion(width: 300, height: 250, resources: [.html("<div>c</div>")])
    private static let unshowable = VASTCompanion(width: 300, height: 250)

    /// AdTech review: an ad whose `CompanionAds@required` cannot be met is not played: Error 602, and the pod moves on.
    /// A CTV player shows no companions, so any requirement over companions fails there.
    @Test func anAdWhoseRequiredCompanionsCannotBeShownIsNotPlayed() async {
        let (model, host, engine) = make([requiringCompanions(.all, [Self.htmlCompanion])], device: RendererFixtures.tv, placement: .ctvInstream)
        model.start()
        #expect(await Wait.until { model.phase == .finished })
        #expect(host.events == [.error(.requiredCompanionUnavailable, adIndex: 0)])
        #expect(engine.loaded.isEmpty, "the media is never loaded")
        #expect(model.lastError == .requiredCompanionUnavailable)
    }

    @Test(arguments: [VASTCompanionRequirement.all, .any])
    func aPhoneShowsRequiredCompanionsAndPlays(_ requirement: VASTCompanionRequirement) async {
        let (model, host, engine) = make([requiringCompanions(requirement, [Self.htmlCompanion])])
        model.start()
        await waitForLoad(engine)
        #expect(!host.events.contains { if case .error = $0 { true } else { false } })
    }

    /// `all` with one companion the player cannot show (no resource it renders) fails; `any` with one it can show plays.
    @Test func allNeedsEveryCompanionAnyNeedsOne() async {
        let (allModel, allHost, _) = make([requiringCompanions(.all, [Self.htmlCompanion, Self.unshowable])])
        allModel.start()
        #expect(await Wait.until { allModel.phase == .finished })
        #expect(allHost.events == [.error(.requiredCompanionUnavailable, adIndex: 0)])

        let (anyModel, anyHost, anyEngine) = make([requiringCompanions(.any, [Self.unshowable, Self.htmlCompanion])])
        anyModel.start()
        await waitForLoad(anyEngine)
        #expect(anyHost.events.isEmpty || !anyHost.events.contains(.error(.requiredCompanionUnavailable, adIndex: 0)),
                "\(anyHost.events) \(anyHost.logs.map(\.message))")
    }

    /// In a pod, the failing ad is skipped and the next one plays.
    @Test func thePodMovesOnPastAnUnsatisfiableAd() async {
        let first = requiringCompanions(.any, [Self.unshowable], media: "https://cdn.example/1.mp4")
        let second = RendererFixtures.linearAd(duration: 2, media: [VASTMediaFile(url: "https://cdn.example/2.mp4", type: "video/mp4")])
        let (model, host, engine) = make([first, second])
        model.start()
        await waitForLoad(engine)
        #expect(host.events.first == .error(.requiredCompanionUnavailable, adIndex: 0))
        #expect(engine.loaded.count == 1, "only the second ad's media")
    }

    /// The player reports the media file it chose (the host's `[ASSETURI]`) before the ad's first event.
    @Test func thePlayerReportsTheMediaFileItChose() async {
        let media = [VASTMediaFile(url: "https://cdn.example/low.mp4", type: "video/mp4", width: 320, height: 180),
                     VASTMediaFile(url: "https://cdn.example/high.mp4", type: "video/mp4", width: 1280, height: 720)]
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 4, media: media)],
                                         choose: { files, _, _, _ in .play(files[1]) })
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 4))
        #expect(host.statuses.last?.assetURI == "https://cdn.example/high.mp4")
        let firstEvent = host.events.firstIndex(of: .video(.loaded, adIndex: 0))
        #expect(firstEvent != nil)
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
        #expect(playingTicks.count >= 4 && playingTicks.count <= 8, "\(playingTicks.map(\.playhead))")
        #expect(zip(host.statuses, host.statuses.dropFirst()).allSatisfy { $0 != $1 }, "no status is reported twice in a row")
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

    /// A click-through opened another app, a store or the in-app browser over the publisher app: a full-screen video
    /// pauses as an SDK's does (its quartiles do not run on behind the cover), and resumes when the app is back — unless
    /// the user had paused it.
    @Test func aCoveredPlayerPausesAndResumesWhenUncovered() async {
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 10)], placement: .interstitial)
        model.start()
        await waitForLoad(engine)
        engine.send(.ready(duration: 10))
        engine.tick(from: 0, to: 1)
        model.setCovered(true)
        #expect(!engine.isPlaying)
        model.setVisibleFraction(1)
        #expect(!engine.isPlaying, "covered, whatever the visible fraction")
        model.setCovered(false)
        #expect(engine.isPlaying)
        #expect(host.videoEvents(adIndex: 0).suffix(2) == [.pause, .resume])
        model.togglePlayback()
        model.setCovered(true)
        model.setCovered(false)
        #expect(!engine.isPlaying, "the user's pause stands")
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
        #expect(host.navigations.isEmpty, "an image companion: the .companionClick plan records the CompanionClickThrough navigation")
        model.companionClicked(choice, adIndex: 0, url: "https://adv.example/elsewhere")
        #expect(host.navigations.isEmpty, "an image companion never navigates from the player")
    }

    /// A companion is part of its ad: it shows once the ad has started (as players show companions on start), and a
    /// companion that reports itself shown earlier (an image decoded during the media load) is viewed only after its
    /// ad's impression and creativeView — never before billing.
    @Test func aCompanionIsViewedOnlyAfterItsAdStarted() async {
        let companion = VASTCompanion(id: "c", width: 300, height: 250,
                                      resources: [.staticResource(url: "https://c.example/c.png", creativeType: "image/png")])
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 2, companions: [companion])])
        model.start()
        await waitForLoad(engine)
        #expect(!model.currentAdStarted)
        let choice = CompanionChoice(companionIndex: 0, companion: companion, resource: .image(url: "https://c.example/c.png"))
        model.companionDidAppear(choice, adIndex: 0)
        #expect(!host.events.contains(.companionView(adIndex: 0, companionIndex: 0)), "not before the ad starts")
        engine.send(.ready(duration: 2))
        engine.tick(from: 0, to: 0.5)
        #expect(model.currentAdStarted)
        let creativeView = host.events.firstIndex(of: .video(.creativeView, adIndex: 0)) ?? .max
        let companionView = host.events.firstIndex(of: .companionView(adIndex: 0, companionIndex: 0)) ?? .min
        #expect(creativeView < companionView, "\(host.events)")
        #expect((host.events.firstIndex(of: .rendered) ?? .max) < companionView)
        model.companionDidAppear(choice, adIndex: 0)
        #expect(host.events.filter { $0 == .companionView(adIndex: 0, companionIndex: 0) }.count == 1)
    }

    /// HTML / iframe / script companions open their own click-through; the plan does not navigate for them.
    @Test func htmlCompanionsNavigateToWhatTheyOpened() async {
        let companion = VASTCompanion(id: "h", width: 300, height: 250, resources: [.html("<a href='https://adv.example/companion'>x</a>")],
                                      clickThrough: "https://adv.example/companion")
        let (model, host, engine) = make([RendererFixtures.linearAd(duration: 2, companions: [companion])])
        model.start()
        await waitForLoad(engine)
        let choice = CompanionChoice(companionIndex: 0, companion: companion, resource: .html("<a href='https://adv.example/companion'>x</a>"))
        model.companionClicked(choice, adIndex: 0, url: "https://adv.example/companion")
        #expect(host.events.last == .companionClick(adIndex: 0, companionIndex: 0))
        #expect(host.navigations == [.init(url: "https://adv.example/companion", trigger: "companion creative navigation", vastAdIndex: 0)],
                "exactly one navigation, even to the CompanionClickThrough URL, under its ad's hop")
        model.companionClicked(choice, adIndex: 0, url: nil)
        #expect(host.navigations.count == 1)
    }
}

/// Safety review (Offline): when nothing played because the session is Offline, the player says so — not a bare
/// "VAST error 301" that reads like the ad server's fault.
@Suite("Player messages")
struct PlayerMessageTests {
    @Test func offlineExplainsWhyNothingPlayed() {
        let offline = VASTPlayerMessages.nothingPlayed(lastError: .wrapperTimeout, offline: true)
        #expect(offline.title == "Offline")
        #expect(offline.detail.contains("not loaded") && offline.detail.contains("Simulated") && offline.detail.contains("301"))
        let online = VASTPlayerMessages.nothingPlayed(lastError: .noSupportedMedia, offline: false)
        #expect(online.title == "VAST error 403")
        #expect(online.detail == "No media file this player can play.")
        #expect(VASTPlayerMessages.nothingPlayed(lastError: nil, offline: false).title == "Nothing to play")
        #expect(VASTPlayerMessages.nothingPlayed(lastError: nil, offline: true).title == "Offline")
    }
}
