import CoreGraphics
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("Renderer selection")
struct RendererKindTests {
    @Test func picksTheRendererFromTheMarkup() {
        #expect(RendererKind.resolve(RendererFixtures.request(.html("<b>hi</b>"))) == .html("<b>hi</b>"))
        let banner = ImageBanner(imageURL: "data:image/png;base64,AA==")
        #expect(RendererKind.resolve(RendererFixtures.request(.image(banner))) == .image(banner))
        let native = NativeAd(assets: [NativeAsset(id: 1, content: .title(text: "T"))])
        #expect(RendererKind.resolve(RendererFixtures.request(.native("{}"), format: .native, native: native)) == .native(native))
    }

    @Test func explainsWhatCannotBeDrawn() {
        guard case .message = RendererKind.resolve(RendererFixtures.request(.html("  \n"))) else { Issue.record("empty html"); return }
        guard case .message = RendererKind.resolve(RendererFixtures.request(.native("{"), format: .native)) else {
            Issue.record("unparsed native"); return
        }
        guard case .message = RendererKind.resolve(RendererFixtures.request(.none)) else { Issue.record("nurl markup"); return }
        guard case .message = RendererKind.resolve(RendererFixtures.request(.vast(.xml("<VAST/>")), format: .video)) else {
            Issue.record("unresolved vast"); return
        }
        let failed = ResolvedVAST(failure: .noAdsAfterWrapper)
        guard case let .message(title, _) = RendererKind.resolve(RendererFixtures.request(.vast(.xml("<VAST/>")), format: .video, vast: failed))
        else { Issue.record("failed vast"); return }
        #expect(title == "VAST error 303")
    }

    @Test func audioComesFromTheFormatOrTheMediaTypes() {
        let video = ResolvedVAST(ads: [RendererFixtures.linearAd()])
        let audioMedia = [VASTMediaFile(url: "https://cdn.example/a.mp3", type: "audio/mpeg")]
        let audio = ResolvedVAST(ads: [RendererFixtures.linearAd(media: audioMedia)])
        #expect(RendererKind.resolve(RendererFixtures.request(.vast(.xml("")), format: .video, vast: video)) == .video(video))
        #expect(RendererKind.resolve(RendererFixtures.request(.vast(.xml("")), format: .audio, vast: video)) == .audio(video))
        #expect(RendererKind.resolve(RendererFixtures.request(.vast(.xml("")), format: .video, vast: audio)) == .audio(audio))
    }
}

@Suite("HTML document")
struct HTMLDocumentBuilderTests {
    @Test func wrapsAFragment() {
        let document = HTMLDocumentBuilder.document(for: "<div id=ad>Ad</div>")
        #expect(document.hasPrefix("<!DOCTYPE html>"))
        #expect(document.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1">"#))
        #expect(document.contains("margin:0"))
        #expect(document.contains("<body><div id=ad>Ad</div></body>"))
        #expect(document.contains(HTMLDocumentBuilder.dnsPrefetchOff))
    }

    @Test func keepsAFullDocumentAndOnlyAddsTheDNSSwitch() {
        let full = "<!doctype html><HTML lang=en><Head data-x=1><title>x</title></head><body>Ad</body></HTML>"
        let document = HTMLDocumentBuilder.document(for: full)
        #expect(document == full.replacingOccurrences(of: "<Head data-x=1>", with: "<Head data-x=1>" + HTMLDocumentBuilder.dnsPrefetchOff))
        let headless = "<html><body><header>h</header></body></html>"
        #expect(HTMLDocumentBuilder.document(for: headless) == "<html><head>\(HTMLDocumentBuilder.dnsPrefetchOff)</head><body><header>h</header></body></html>")
    }
}

@Suite("MRAID environment")
struct MRAIDEnvironmentTests {
    @Test func inlineBanner() {
        let environment = MRAIDEnvironment(request: RendererFixtures.request(.html("x"), visibleFraction: 0.456))
        #expect(environment.placementType == "inline")
        #expect(environment.screenSize == MRAIDSize(width: 390, height: 844))
        #expect(environment.maxSize == MRAIDSize(width: 390, height: 763))
        #expect(environment.defaultPosition == MRAIDRect(x: 35, y: 0, width: 320, height: 50), "relative to the max-size area")
        #expect(environment.exposedPercentage == 45.6)
        #expect(environment.disableScroll)
        #expect(environment.supports["inlineVideo"] == true)
        #expect(environment.supports["sms"] == false)
    }

    /// AdTech review: MRAID 3.0 §3.2 `MRAID_ENV.appId` is the PUBLISHER's app (the request's `app.bundle`), else the
    /// simulated host app's own id — never the advertiser's `bid.bundle`.
    @Test func appIDIsThePublishersAppNeverTheBidBundle() {
        var request = RendererFixtures.request(.html("x"))
        request.candidate.bundle = "com.advertiser.game"
        #expect(MRAIDEnvironment(request: request).appID == Placement.inlineBanner.simulatedAppBundle)
        request.publisherAppBundle = "com.publisher.news"
        #expect(MRAIDEnvironment(request: request).appID == "com.publisher.news")
        for placement in Placement.allCases {
            #expect(placement.simulatedAppBundle.hasPrefix("com.example."), "\(placement)")
        }
    }

    @Test func interstitialIsCenteredAndScrollable() {
        let request = RendererFixtures.request(.html("x"), placement: .rewarded, adSize: CGSize(width: 320, height: 480))
        let environment = MRAIDEnvironment(request: request)
        #expect(environment.placementType == "interstitial")
        #expect(environment.defaultPosition == MRAIDRect(x: 35, y: 142, width: 320, height: 480))
        #expect(!environment.disableScroll)
    }

    @Test func landscapeFoldedAndSpanned() {
        var request = RendererFixtures.request(.html("x"), landscape: true)
        #expect(MRAIDEnvironment.screenSize(request) == MRAIDSize(width: 844, height: 390))
        request.device = RendererFixtures.foldable
        request.landscape = false
        request.folded = true
        #expect(MRAIDEnvironment.screenSize(request) == MRAIDSize(width: 360, height: 780))
        request.device = RendererFixtures.duo
        request.folded = false
        request.spanned = true
        #expect(MRAIDEnvironment.screenSize(request) == MRAIDSize(width: 1114, height: 720))
        request.device = RendererFixtures.tv
        request.spanned = false
        request.landscape = true
        #expect(MRAIDEnvironment.screenSize(request) == MRAIDSize(width: 1920, height: 1080))
    }

    @Test func exposureIsClampedAndFinite() {
        #expect(MRAIDEnvironment.percentage(.nan) == 0)
        #expect(MRAIDEnvironment.percentage(-1) == 0)
        #expect(MRAIDEnvironment.percentage(3) == 100)
    }

    @Test func encodesAsJSON() throws {
        let json = MRAIDEnvironment(request: RendererFixtures.request(.html("x"))).json()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["version"] as? String == "3.0")
        #expect(object["placementType"] as? String == "inline")
    }
}

@Suite("Bridge messages")
struct BridgeMessageTests {
    @Test func decodesMRAIDCommands() {
        #expect(BridgeMessage.decode(["channel": "mraid", "name": "open", "args": ["url": "https://a.example"], "description": "open(…)"])
            == .mraid(.open(url: "https://a.example"), description: "open(…)"))
        #expect(BridgeMessage.decode(["channel": "mraid", "name": "expand", "args": ["url": ""]]) == .mraid(.expand(url: nil), description: "expand()"))
        #expect(BridgeMessage.decode(["channel": "mraid", "name": "useCustomClose", "args": ["value": true]])
            == .mraid(.useCustomClose(true), description: "useCustomClose()"))
        #expect(BridgeMessage.decode(["channel": "mraid", "name": "getState"]) == .mraid(.other, description: "getState()"))
        #expect(BridgeMessage.decode(["channel": "mraid", "name": "open", "args": [:] as [String: Any]]) == .mraid(.other, description: "open()"))
    }

    @Test func decodesTheOtherChannels() {
        #expect(BridgeMessage.decode(["channel": "net", "phase": "start", "rid": "a:1", "url": "https://t.example/p", "kind": "fetch"])
            == .network(.start(rid: "a:1", url: "https://t.example/p", kind: "fetch")))
        #expect(BridgeMessage.decode(["channel": "state", "state": "expanded", "customClose": true]) == .mraidState("expanded", customClose: true, size: nil))
        #expect(BridgeMessage.decode(["channel": "state", "state": "resized", "width": 300, "height": 250])
            == .mraidState("resized", customClose: false, size: MRAIDSize(width: 300, height: 250)))
        #expect(BridgeMessage.decode(["channel": "gesture"]) == nil, "gestures are seen natively: the page cannot report one")
        #expect(BridgeMessage.decode(["channel": "console", "level": "error", "message": "boom"]) == .console(level: "error", message: "boom"))
    }

    @Test func dropsMalformedMessages() {
        #expect(BridgeMessage.decode("open") == nil)
        #expect(BridgeMessage.decode(["name": "open"]) == nil)
        #expect(BridgeMessage.decode(["channel": "net", "url": 42]) == nil)
        #expect(BridgeMessage.decode(["channel": "state", "state": "flying"]) == nil)
        #expect(BridgeMessage.decode(["channel": "unknown"]) == nil)
    }

    @Test func capsHugeStrings() {
        let huge = String(repeating: "a", count: BridgeMessage.maxStringLength * 2)
        guard case let .network(.start(_, url, _)) = BridgeMessage.decode(["channel": "net", "phase": "start", "rid": "a:1", "url": huge]) else {
            Issue.record("not decoded")
            return
        }
        #expect(url.count == BridgeMessage.maxStringLength + 1)
    }
}

@Suite("Player controls")
struct PlayerControlStateTests {
    @Test func skipCountdownThenAvailable() {
        #expect(SkipButtonState.make(skipOffset: nil, playhead: 3, duration: 15) == .hidden)
        #expect(SkipButtonState.make(skipOffset: .seconds(5), playhead: 0, duration: 15) == .countdown(5))
        #expect(SkipButtonState.make(skipOffset: .seconds(5), playhead: 4.2, duration: 15) == .countdown(1))
        #expect(SkipButtonState.make(skipOffset: .seconds(5), playhead: 5, duration: 15) == .available)
        #expect(SkipButtonState.make(skipOffset: .seconds(5), playhead: 6, duration: 15, enabled: false) == .hidden)
    }

    @Test func skipOffsetsThatCannotApplyAreHidden() {
        #expect(SkipButtonState.make(skipOffset: .seconds(20), playhead: 0, duration: 15) == .hidden)
        #expect(SkipButtonState.make(skipOffset: .percent(50), playhead: 0, duration: nil) == .hidden)
        #expect(SkipButtonState.make(skipOffset: .percent(50), playhead: 1, duration: 10) == .countdown(4))
        #expect(SkipButtonState.make(skipOffset: .seconds(-1), playhead: 1, duration: 10) == .hidden)
        #expect(SkipButtonState.make(skipOffset: .seconds(5), playhead: .nan, duration: 10) == .countdown(5))
    }

    @Test func clock() {
        #expect(PlayerClock.format(15) == "0:15")
        #expect(PlayerClock.format(14.2) == "0:15")
        #expect(PlayerClock.format(65) == "1:05")
        #expect(PlayerClock.format(-3) == "0:00")
        #expect(PlayerClock.format(.infinity) == "0:00")
        #expect(PlayerClock.remaining(playhead: 4, duration: 15) == 11)
        #expect(PlayerClock.remaining(playhead: 20, duration: 15) == 0)
        #expect(PlayerClock.fraction(playhead: 7.5, duration: 15) == 0.5)
        #expect(PlayerClock.fraction(playhead: 1, duration: nil) == 0)
    }

    @Test func ctvFocusMovesAlongTheRowWithoutWrapping() {
        var focus = CTVFocusModel()
        #expect(focus.focused == .playPause)
        focus.move(.right)
        #expect(focus.focused == .playPause, "only Play/Pause is on screen")
        focus.setAvailable([.playPause, .skip])
        focus.move(.right)
        #expect(focus.focused == .skip)
        focus.move(.down)
        #expect(focus.focused == .skip)
        focus.move(.left)
        #expect(focus.focused == .playPause)
        focus.move(.up)
        #expect(focus.focused == .playPause)
        focus.move(.right)
        focus.setAvailable([.playPause])
        #expect(focus.focused == .playPause, "focus falls back when Skip disappears")
        focus.setAvailable([])
        #expect(focus.available == [.playPause])
    }
}

@Suite("Full-screen chrome")
struct FullscreenChromePolicyTests {
    @Test func interstitialCloseAppearsAfterFiveSeconds() {
        #expect(FullscreenChromePolicy.phase(placement: .interstitial, elapsed: 0) == .closeIn(5))
        #expect(FullscreenChromePolicy.phase(placement: .interstitial, elapsed: 4.5) == .closeIn(1))
        #expect(FullscreenChromePolicy.phase(placement: .interstitial, elapsed: 5) == .closable)
    }

    @Test func rewardedCountsDownTheReward() {
        #expect(FullscreenChromePolicy.phase(placement: .rewarded, elapsed: 0) == .rewardIn(15))
        #expect(FullscreenChromePolicy.phase(placement: .rewarded, elapsed: 3, rewardDuration: 10) == .rewardIn(7))
        #expect(FullscreenChromePolicy.phase(placement: .rewarded, elapsed: 10, rewardDuration: 10) == .closable)
        #expect(FullscreenChromePolicy.phase(placement: .rewarded, elapsed: .nan, rewardDuration: .infinity) == .rewardIn(15))
    }

    @Test func inlinePlacementsHaveNoChrome() {
        for placement in [Placement.inlineBanner, .inFeed, .ctvInstream] {
            #expect(FullscreenChromePolicy.phase(placement: placement, elapsed: 100) == .none)
        }
    }
}

@Suite("CTV remote")
struct CTVRemoteTests {
    @Test func arrowsMoveTheFocusAndSelectActivatesIt() {
        var focus = CTVFocusModel()
        focus.setAvailable([.playPause, .skip])
        #expect(CTVRemote.handle(.select, focus: &focus) == .togglePlayback)
        #expect(CTVRemote.handle(.right, focus: &focus) == CTVRemoteAction.none)
        #expect(focus.focused == .skip)
        #expect(CTVRemote.handle(.select, focus: &focus) == .skip)
        #expect(CTVRemote.handle(.right, focus: &focus) == CTVRemoteAction.none)
        #expect(focus.focused == .skip, "no wrapping")
        #expect(CTVRemote.handle(.up, focus: &focus) == CTVRemoteAction.none)
        #expect(focus.focused == .playPause)
    }

    @Test func playPauseAndBackWorkWhateverHasFocus() {
        var focus = CTVFocusModel()
        focus.setAvailable([.playPause, .skip])
        _ = CTVRemote.handle(.right, focus: &focus)
        #expect(CTVRemote.handle(.playPause, focus: &focus) == .togglePlayback)
        #expect(CTVRemote.handle(.back, focus: &focus) == .close)
    }

    @Test func aDisappearingSkipButtonGivesTheFocusBack() {
        var focus = CTVFocusModel()
        focus.setAvailable([.playPause, .skip])
        _ = CTVRemote.handle(.right, focus: &focus)
        focus.setAvailable([.playPause])
        #expect(focus.focused == .playPause)
        #expect(CTVRemote.handle(.select, focus: &focus) == .togglePlayback)
    }
}

@Suite("Hostile durations")
struct HostileDurationTests {
    @Test func hugeOffsetsAndDurationsNeverTrap() {
        #expect(PlayerClock.format(1e300) == "16666666:40", "clamped to 10^9 s")
        #expect(PlayerClock.format(.greatestFiniteMagnitude) == "16666666:40")
        #expect(SkipButtonState.make(skipOffset: .seconds(3.6e23), playhead: 0, duration: nil) == .countdown(1_000_000_000))
        #expect(SkipButtonState.make(skipOffset: .seconds(3.6e23), playhead: 0, duration: 15) == .hidden)
        #expect(SkipButtonState.make(skipOffset: .percent(50), playhead: 0, duration: 1e300) == .countdown(1_000_000_000))
    }
}
