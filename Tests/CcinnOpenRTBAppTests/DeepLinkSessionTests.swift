import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

/// A click-through on the device: what opens, what covers the ad, and what the Network entry and the log say.
@MainActor
@Suite("Deep links and app jumps (session)")
struct DeepLinkSessionTests {
    private let display = Fixtures.candidate(.html("<div>ad</div>"))

    /// A session whose click opens `url` (with the bid's `fallback`), rendered and ready.
    private func rendered(click url: String, fallback: String? = nil, device: DeviceProfile? = nil, opensClickThroughs: Bool = false,
                          real: Bool = false) async -> SessionHarness {
        let harness = SessionHarness(Fixtures.input([display]), opensClickThroughs: opensClickThroughs) { services in
            let base = services.trackingRequests
            services.trackingRequests = { event, candidate, native, vast, context, options in
                base(event, candidate, native, vast, context, options).map { request in
                    guard request.category == .navigation else { return request }
                    var navigation = request
                    navigation.url = url
                    navigation.template = url
                    navigation.fallback = fallback
                    return navigation
                }
            }
        }
        await harness.paste()
        if let device { harness.session.device = device }
        if real { harness.enterRealMode() }
        await harness.renderAndWait()
        return harness
    }

    private func navigation(_ harness: SessionHarness) -> NetworkEntry? {
        harness.monitor.liveEntries.last { $0.category == .navigation }
    }

    @Test func aDeepLinkOpensItsInstalledApp() async throws {
        let harness = await rendered(click: "lazada://product/123?utm=ad")
        harness.session.fireManually(.click(assetID: nil))
        let foreground = try #require(harness.session.foreground)
        #expect(foreground.screen == .app(ThirdPartyApp(name: "Lazada", identifier: "lazada:", link: "lazada://product/123?utm=ad", route: "product/123",
                                                        parameters: [LinkParameter("utm", "ad")])))
        #expect(foreground.platform == .apple && !foreground.usedFallback)
        #expect(harness.session.clickThroughNotice == nil)
        #expect(navigation(harness)?.note == "Deep link: Lazada (lazada:) is installed and opens it")
        #expect(navigation(harness)?.delivery == .simulated)
        #expect(harness.session.lifecycleLog.contains { $0.label == "Deep link: Lazada (lazada:) is installed and opens it" && $0.origin == "device"
            && $0.outcome == .fired(requests: 0) })
    }

    @Test func notInstalledOpensTheFallback() async throws {
        let harness = await rendered(click: "lazada://product/123", fallback: "https://www.lazada.com.my/p/123")
        harness.session.appsInstalled = false
        harness.session.fireManually(.click(assetID: nil))
        let foreground = try #require(harness.session.foreground)
        #expect(foreground.screen == .browser(WebPage(url: "https://www.lazada.com.my/p/123", host: "www.lazada.com.my", parameters: [])))
        #expect(foreground.usedFallback)
        #expect(navigation(harness)?.note?.hasPrefix("Deep link: no installed app opens lazada: links → Fallback https://www.lazada.com.my/p/123") == true)
    }

    @Test func nothingToOpenLeavesTheAdWithANotice() async throws {
        let harness = await rendered(click: "lazada://product/123")
        harness.session.appsInstalled = false
        harness.session.fireManually(.click(assetID: nil))
        #expect(harness.session.foreground == nil)
        let notice = try #require(harness.session.clickThroughNotice)
        #expect(notice.text == "Deep link: no installed app opens lazada: links. No fallback in the bid: nothing opens.")
        #expect(harness.session.renderRequest?.visibleFraction == 1, "the ad stays in view")
        #expect(harness.session.lifecycleLog.contains { $0.origin == "device" && $0.outcome == .ignored("nothing opens") })
        harness.session.dismissClickThroughNotice()
        #expect(harness.session.clickThroughNotice == nil)
    }

    @Test func theAdIsOutOfViewWhileAnotherScreenCoversIt() async throws {
        let harness = await rendered(click: "https://adv.example/landing")
        harness.clock.set(10)
        harness.session.report(.rendered)
        harness.session.fireManually(.click(assetID: nil))
        #expect(harness.session.foreground != nil)
        #expect(harness.session.renderRequest?.visibleFraction == 0)
        #expect(harness.session.visibleFraction == 1, "the app's own geometry is unchanged under the cover")
        harness.clock.set(15)
        harness.session.settleViewability()
        #expect(!harness.recorder.events.contains(.viewable(.mrc50)), "covered, the ad is not viewable")
        harness.session.returnToApp()
        #expect(harness.session.foreground == nil)
        #expect(harness.session.renderRequest?.visibleFraction == 1)
        harness.clock.set(16.1)
        harness.session.settleViewability()
        #expect(harness.recorder.events.contains(.viewable(.mrc50)))
    }

    @Test func renderAndResetCloseTheJump() async throws {
        let harness = await rendered(click: "lazada://p")
        harness.session.fireManually(.click(assetID: nil))
        #expect(harness.session.foreground != nil)
        harness.session.reset()
        #expect(harness.session.foreground == nil)
        await harness.renderAndWait()
        harness.session.fireManually(.click(assetID: nil))
        #expect(harness.session.foreground != nil)
        harness.session.device = RendererFixtures.android
        #expect(harness.session.foreground == nil, "another device is another phone")
    }

    @Test func aConnectedTVNeverJumps() async throws {
        let harness = await rendered(click: "lazada://p", device: RendererFixtures.tv)
        harness.session.navigate(to: "lazada://p", trigger: "mraid.open", source: "creative")
        #expect(harness.session.foreground == nil && harness.session.clickThroughNotice == nil)
    }

    @Test func androidResolvesIntentsAndStores() async throws {
        let harness = await rendered(click: "intent://item/9#Intent;scheme=shopee;package=com.shopee.my;end", device: RendererFixtures.android)
        harness.session.fireManually(.click(assetID: nil))
        if case let .app(app) = harness.session.foreground?.screen { #expect(app.name == "Shopee" && app.link == "shopee://item/9") } else {
            Issue.record("\(String(describing: harness.session.foreground))")
        }
        harness.session.returnToApp()
        harness.session.appsInstalled = false
        harness.session.navigate(to: "intent://item/9#Intent;scheme=shopee;package=com.shopee.my;end", trigger: "mraid.open", source: "creative")
        if case let .store(page) = harness.session.foreground?.screen { #expect(page.store == .googlePlay && page.appID == "com.shopee.my") } else {
            Issue.record("\(String(describing: harness.session.foreground))")
        }
    }

    /// iOS's "◀ App" appears after a jump to another app (a deep link's app, Phone, the App Store app for `itms-apps:`),
    /// not over the in-app browser or the App Store sheet an SDK shows for an `https` link; Android has its Back.
    @Test func theBreadcrumbFollowsWhetherAnotherAppOpened() {
        func foreground(_ screen: ClickThroughScreen, _ platform: DevicePlatform) -> DeviceForeground {
            DeviceForeground(screen: screen, platform: platform, usedFallback: false, openedOnMac: false)
        }
        let app = ClickThroughScreen.app(ThirdPartyApp(name: "A", identifier: "a:", link: "a://", route: "", parameters: []))
        let web = ClickThroughScreen.browser(WebPage(url: "https://a.example", host: "a.example", parameters: []))
        let sheet = ClickThroughScreen.store(StorePage(store: .appStore, appID: "id1", url: "https://apps.apple.com/app/id1", parameters: []))
        let storeApp = ClickThroughScreen.store(StorePage(store: .appStore, appID: "id1", url: "itms-apps://apps.apple.com/app/id1", parameters: []))
        let play = ClickThroughScreen.store(StorePage(store: .googlePlay, appID: "p", url: "https://play.google.com/store/apps/details?id=p", parameters: []))
        #expect(foreground(app, .apple).showsBackBreadcrumb && foreground(.system(.phone, target: "1"), .apple).showsBackBreadcrumb)
        #expect(foreground(storeApp, .apple).showsBackBreadcrumb)
        #expect(!foreground(web, .apple).showsBackBreadcrumb && !foreground(sheet, .apple).showsBackBreadcrumb)
        #expect(foreground(app, .android).jumpedToAnotherApp && !foreground(app, .android).showsBackBreadcrumb)
        #expect(foreground(play, .android).jumpedToAnotherApp && !foreground(web, .android).jumpedToAnotherApp)
    }

    /// Review: `mraid.playVideo` hands a video to the SDK's own player — recorded, never shown as the in-app browser.
    @Test func mraidPlayVideoIsNotAJump() async throws {
        let harness = await rendered(click: "https://adv.example/")
        harness.session.navigate(to: "https://cdn.example/v.mp4", trigger: "mraid.playVideo (native player)", source: "creative")
        #expect(harness.session.foreground == nil && harness.session.clickThroughNotice == nil)
        #expect(navigation(harness)?.url == "https://cdn.example/v.mp4")
        #expect(harness.session.renderRequest?.visibleFraction == 1)
    }

    /// Lose and a placement change end the play, and the jump with it.
    @Test func loseAndAPlacementChangeCloseTheJump() async throws {
        let harness = await rendered(click: "lazada://p")
        harness.session.fireManually(.click(assetID: nil))
        harness.session.placement = harness.session.placement == .interstitial ? .inlineBanner : .interstitial
        #expect(harness.session.foreground == nil)
        await harness.renderAndWait()
        harness.session.fireManually(.click(assetID: nil))
        #expect(harness.session.foreground != nil)
        harness.session.lose(.lostToHigherBid)
        #expect(harness.session.foreground == nil)
    }

    @Test func aRendererNavigationJumpsToo() async throws {
        let harness = await rendered(click: "https://adv.example/")
        harness.session.navigate(to: "tel:+60123456789", trigger: "mraid.open", source: "creative")
        #expect(harness.session.foreground?.screen == .system(.phone, target: "+60123456789"))
    }

    /// Real mode with "Open click-throughs in browser": the Mac opens the web page the device shows — a fallback included
    /// — and never a deep link.
    @Test func realModeOpensTheShownWebPageOnTheMac() async throws {
        let installed = await rendered(click: "lazada://p", fallback: "https://lazada.example/p", opensClickThroughs: true, real: true)
        installed.session.fireManually(.click(assetID: nil))
        #expect(installed.browser.opened.isEmpty)
        #expect(installed.session.foreground?.openedOnMac == false)

        let fallback = await rendered(click: "lazada://p", fallback: "https://lazada.example/p", opensClickThroughs: true, real: true)
        fallback.session.appsInstalled = false
        fallback.session.fireManually(.click(assetID: nil))
        #expect(fallback.browser.opened == [URL(string: "https://lazada.example/p")])
        #expect(fallback.session.foreground?.openedOnMac == true)
        #expect(navigation(fallback)?.delivery == .browser)
        #expect(navigation(fallback)?.note?.hasSuffix(" · opened in the default browser") == true)
    }
}
