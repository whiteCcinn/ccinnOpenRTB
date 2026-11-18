import CoreGraphics
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// AdTech review (decided): VAST industry icons (AdChoices …) — the player draws an icon's StaticResource image at its
/// position and size, from its offset for its duration; IconViewTracking fires when it shows, IconClickTracking and the
/// IconClickThrough navigation when it is clicked. No icons on CTV.
@Suite("VAST icons")
struct VASTIconPlanTests {
    private static func icon(program: String? = "AdChoices", url: String = "https://icons.example/adchoices.png", type: String? = "image/png",
                             width: Int? = 77, height: Int? = 15, x: VASTIcon.HorizontalPosition? = .right, y: VASTIcon.VerticalPosition? = .top,
                             offset: Double? = nil, duration: Double? = nil) -> VASTIcon {
        VASTIcon(program: program, width: width, height: height, xPosition: x, yPosition: y, duration: duration, offset: offset,
                 resources: [.staticResource(url: url, creativeType: type)], clickThrough: "https://privacy.example/", clickTrackings: ["https://t.example/ic"],
                 viewTrackings: ["https://t.example/iv"])
    }

    @Test func onlyImageIconsAreDrawnAndTheInlineAdsWinPerProgram() {
        let wrapperIcon = Self.icon(url: "https://icons.example/wrapper.png")
        let html = VASTIcon(program: "Other", width: 20, height: 20, resources: [.html("<b>i</b>")])
        let script = Self.icon(program: "Script", url: "https://icons.example/i.js", type: "application/javascript")
        let inlineIcon = Self.icon(url: "https://icons.example/inline.png")
        let untyped = Self.icon(program: nil, url: "https://icons.example/logo.gif", type: nil)
        let icons = VASTIconPlan.icons([wrapperIcon, html, script, inlineIcon, untyped])
        #expect(icons.map(\.iconIndex) == [3, 4], "\(icons)")
        #expect(icons.map(\.imageURL) == ["https://icons.example/inline.png", "https://icons.example/logo.gif"])
    }

    @Test func positionsAndSizesInThePlayer() {
        let player = CGSize(width: 400, height: 225)
        func frame(_ x: VASTIcon.HorizontalPosition?, _ y: VASTIcon.VerticalPosition?, width: Int? = 77, height: Int? = 15) -> CGRect? {
            VASTIconPlan.icons([Self.icon(width: width, height: height, x: x, y: y)]).first?.frame(in: player)
        }
        #expect(frame(.right, .top) == CGRect(x: 323, y: 0, width: 77, height: 15))
        #expect(frame(.left, .bottom) == CGRect(x: 0, y: 210, width: 77, height: 15))
        #expect(frame(.pixels(10), .pixels(20)) == CGRect(x: 10, y: 20, width: 77, height: 15))
        #expect(frame(.pixels(390), .pixels(220)) == CGRect(x: 323, y: 210, width: 77, height: 15), "kept inside the player")
        #expect(frame(nil, nil) == CGRect(x: 323, y: 0, width: 77, height: 15), "default: top right")
        #expect(frame(.left, .top, width: nil, height: nil) == CGRect(x: 0, y: 0, width: 20, height: 20), "default size")
        #expect(frame(.left, .top, width: 900, height: 900) == CGRect(x: 0, y: 0, width: 400, height: 225), "never larger than the player")
    }

    @Test func offsetAndDuration() throws {
        let always = try #require(VASTIconPlan.icons([Self.icon()]).first)
        #expect(always.isVisible(at: 0) && always.isVisible(at: 1_000))
        let timed = try #require(VASTIconPlan.icons([Self.icon(offset: 2, duration: 3)]).first)
        #expect(!timed.isVisible(at: 1.9))
        #expect(timed.isVisible(at: 2) && timed.isVisible(at: 4.9))
        #expect(!timed.isVisible(at: 5))
    }
}

@MainActor
@Suite("VAST icons in the player")
struct VASTPlayerIconTests {
    private let keepAlive = KeepAlive()

    private func make(device: DeviceProfile = RendererFixtures.phone, placement: Placement = .interstitial) -> (VASTPlayerModel, RecordingHost, FakeEngine) {
        var ad = RendererFixtures.linearAd(duration: 10)
        ad.icons = [VASTIcon(program: "AdChoices", width: 77, height: 15, xPosition: .right, yPosition: .top, offset: 1,
                             resources: [.staticResource(url: "https://icons.example/adchoices.png", creativeType: "image/png")],
                             clickThrough: "https://privacy.example/")]
        let host = keepAlive.hold(RecordingHost(device: device))
        let engine = FakeEngine()
        let configuration = VASTPlayerConfiguration(placement: placement, device: device, playerSize: CGSize(width: 390, height: 219),
                                                    audioOnly: false, source: "bid 0.0 › VAST")
        let model = VASTPlayerModel(vast: ResolvedVAST(ads: [ad]), configuration: configuration, host: host, engine: engine,
                                    chooseMedia: { files, _, _, _ in files.first.map(VASTMediaSelector.Choice.play) ?? .unsupported(.noSupportedMedia) })
        return (model, host, engine)
    }

    @Test func theIconShowsFromItsOffsetAndReportsViewAndClick() async throws {
        let (model, host, engine) = make()
        model.start()
        #expect(await Wait.until { !engine.loaded.isEmpty })
        engine.send(.ready(duration: 10))
        #expect(model.visibleIcons.isEmpty, "not before its offset")
        engine.tick(from: 0, to: 1.5)
        let icon = try #require(model.visibleIcons.first)
        model.iconAppeared(icon)
        model.iconAppeared(icon)
        #expect(host.events.filter { $0 == .iconView(adIndex: 0, iconIndex: 0) }.count == 1)
        model.iconClicked(icon)
        #expect(host.events.last == .iconClick(adIndex: 0, iconIndex: 0))
    }

    /// The integration's "flaky" timeouts, pinned down: a player whose host is gone plays nothing (it holds the host
    /// weakly, as every renderer model does). Tests keep their hosts alive (`KeepAlive`); this proves the bound.
    @Test func aPlayerWithoutItsHostPlaysNothing() async {
        let engine = FakeEngine()
        let configuration = VASTPlayerConfiguration(placement: .interstitial, device: RendererFixtures.phone,
                                                    playerSize: CGSize(width: 390, height: 219), audioOnly: false, source: "bid 0.0 › VAST")
        var host: RecordingHost? = RecordingHost()
        let model = VASTPlayerModel(vast: ResolvedVAST(ads: [RendererFixtures.linearAd(duration: 2)]), configuration: configuration,
                                    host: host ?? RecordingHost(), engine: engine,
                                    chooseMedia: { files, _, _, _ in files.first.map(VASTMediaSelector.Choice.play) ?? .unsupported(.noSupportedMedia) })
        host = nil
        model.start()
        #expect(!(await Wait.until(timeout: .milliseconds(300)) { !engine.loaded.isEmpty }))
    }

    @Test func noIconsOnCTV() async {
        let (model, host, engine) = make(device: RendererFixtures.tv, placement: .ctvInstream)
        model.start()
        #expect(await Wait.until { !engine.loaded.isEmpty }, "\(host.events) \(host.logs.map(\.message))")
        engine.send(.ready(duration: 10))
        engine.tick(from: 0, to: 3)
        #expect(model.visibleIcons.isEmpty)
    }
}
