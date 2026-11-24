import Foundation
import Testing
@testable import RTBKit

@Suite("Click-through resolver")
struct ClickThroughResolverTests {
    private func resolve(_ url: String, fallback: String? = nil, on platform: DevicePlatform = .apple, installed: Bool = true)
        -> ClickThroughResolution {
        ClickThroughResolver.resolve(url, fallback: fallback, platform: platform, appsInstalled: installed)
    }

    @Test func aDeepLinkOpensItsInstalledApp() {
        let resolution = resolve("lazada://product/123?utm_source=ad&price=2.5%25")
        #expect(resolution.screen == .app(ThirdPartyApp(name: "Lazada", identifier: "lazada:", link: "lazada://product/123?utm_source=ad&price=2.5%25",
                                                        route: "product/123", parameters: [LinkParameter("utm_source", "ad"),
                                                                                           LinkParameter("price", "2.5%")])))
        #expect(resolution.steps == ["Deep link: Lazada (lazada:) is installed and opens it"])
        #expect(!resolution.usedFallback)
    }

    @Test func notInstalledUsesTheFallback() {
        let resolution = resolve("lazada://product/123", fallback: " https://www.lazada.com.my/p/123?x=1 ", installed: false)
        #expect(resolution.screen == .browser(WebPage(url: "https://www.lazada.com.my/p/123?x=1", host: "www.lazada.com.my",
                                                      parameters: [LinkParameter("x", "1")])))
        #expect(resolution.usedFallback)
        #expect(resolution.summary == "Deep link: no installed app opens lazada: links → Fallback https://www.lazada.com.my/p/123?x=1: Opens in the in-app browser")
    }

    @Test func notInstalledWithoutAFallbackOpensNothing() {
        let resolution = resolve("lazada://product/123", fallback: "  ", installed: false)
        #expect(resolution.screen == nil)
        #expect(resolution.steps == ["Deep link: no installed app opens lazada: links", "No fallback in the bid: nothing opens"])
    }

    @Test func aFallbackThatCannotOpenEitherOpensNothing() {
        let resolution = resolve("lazada://p", fallback: "shopee://q", installed: false)
        #expect(resolution.screen == nil && !resolution.usedFallback)
        #expect(resolution.steps.last == "Nothing opens")
    }

    @Test func anInstalledAppIgnoresTheFallback() {
        let resolution = resolve("lazada://p", fallback: "https://lazada.com")
        if case .app = resolution.screen {} else { Issue.record("\(String(describing: resolution.screen))") }
        #expect(!resolution.usedFallback)
    }

    @Test func webPagesOpenInTheInAppBrowser() {
        let resolution = resolve("https://adv.example:8443/landing?campaign=${AUCTION_ID}&q=a%20b#top")
        #expect(resolution.screen == .browser(WebPage(url: "https://adv.example:8443/landing?campaign=${AUCTION_ID}&q=a%20b#top", host: "adv.example",
                                                      parameters: [LinkParameter("campaign", "${AUCTION_ID}"), LinkParameter("q", "a b")])))
        #expect(resolve("http://adv.example", on: .android).steps == ["Opens in the in-app browser"])
    }

    @Test func appStoreLinksFollowThePlatform() {
        let url = "https://apps.apple.com/my/app/lazada/id785385147?pt=1&ct=ad"
        #expect(resolve(url).screen == .store(StorePage(store: .appStore, appID: "id785385147", url: url,
                                                        parameters: [LinkParameter("pt", "1"), LinkParameter("ct", "ad")])))
        if case .browser = resolve(url, on: .android).screen {} else { Issue.record("an App Store link is a web page on Android") }
        #expect(resolve("itms-apps://itunes.apple.com/app/id785385147").screen
            == .store(StorePage(store: .appStore, appID: "id785385147", url: "itms-apps://itunes.apple.com/app/id785385147", parameters: [])))
        let android = resolve("itms-apps://itunes.apple.com/app/id785385147", on: .android, installed: true)
        #expect(android.screen == nil && android.steps.first == "No app on Android opens itms-apps: links")
    }

    @Test func googlePlayLinksFollowThePlatform() {
        let url = "https://play.google.com/store/apps/details?id=com.lazada.android&referrer=utm_source%3Dad"
        #expect(resolve(url, on: .android).screen == .store(StorePage(store: .googlePlay, appID: "com.lazada.android", url: url,
                                                                      parameters: [LinkParameter("id", "com.lazada.android"),
                                                                                   LinkParameter("referrer", "utm_source=ad")])))
        if case .browser = resolve(url).screen {} else { Issue.record("a Google Play link is a web page on iOS") }
        #expect(resolve("market://details?id=com.shopee.my", on: .android).screen
            == .store(StorePage(store: .googlePlay, appID: "com.shopee.my", url: "market://details?id=com.shopee.my",
                                parameters: [LinkParameter("id", "com.shopee.my")])))
        #expect(resolve("market://details?id=com.shopee.my").screen == nil)
    }

    @Test func androidIntents() {
        let intent = "intent://item/9?ref=ad#Intent;scheme=shopee;package=com.shopee.my;S.browser_fallback_url=https%3A%2F%2Fshopee.com.my%2F;end"
        #expect(resolve(intent, on: .android).screen == .app(ThirdPartyApp(name: "Shopee", identifier: "com.shopee.my", link: "shopee://item/9?ref=ad",
                                                                          route: "item/9", parameters: [LinkParameter("ref", "ad")])))
        #expect(resolve(intent, on: .android, installed: false).screen == .browser(WebPage(url: "https://shopee.com.my/", host: "shopee.com.my",
                                                                                          parameters: [])))
        let noFallback = "intent://item/9#Intent;scheme=shopee;package=com.shopee.my;end"
        let store = resolve(noFallback, on: .android, installed: false)
        if case let .store(page) = store.screen { #expect(page.store == .googlePlay && page.appID == "com.shopee.my") } else {
            Issue.record("\(store.steps)")
        }
        // iOS has nothing for intents: the bid's fallback opens instead.
        let iOS = resolve(intent, fallback: "https://shopee.com.my/m", installed: true)
        #expect(iOS.usedFallback && iOS.steps.first == "intent: links are Android's: nothing on iOS opens them")
        #expect(resolve("intent://x#Intent;end", on: .android, installed: false).screen == nil)
    }

    @Test func systemApps() {
        #expect(resolve("tel:+60123456789").screen == .system(.phone, target: "+60123456789"))
        #expect(resolve("sms:+60123?body=hi", on: .android).screen == .system(.messages, target: "+60123"))
        #expect(resolve("mailto:sales%40adv.example?subject=x").screen == .system(.mail, target: "sales@adv.example"))
    }

    @Test func notALinkOpensNothing() {
        #expect(resolve("").screen == nil)
        #expect(resolve("just text").screen == nil)
        #expect(resolve("https://adv.example", on: .other).screen == nil)
    }

    @Test func appNames() {
        #expect(ClickThroughResolver.appName(scheme: "fb") == "FB")
        #expect(ClickThroughResolver.appName(scheme: "snssdk1128") == "Snssdk1128")
        #expect(ClickThroughResolver.appName(package: "com.lazada.android") == "Lazada")
        #expect(ClickThroughResolver.appName(package: "com.shopee.my") == "Shopee")
        #expect(ClickThroughResolver.appName(package: "com.zhiliaoapp.musically") == "Musically")
        #expect(ClickThroughResolver.appName(package: "android") == "Android")
    }

    @Test func platforms() {
        func device(_ os: String) -> DeviceProfile {
            DeviceProfile(id: os, name: os, family: .iPhone, screenWidth: 1, screenHeight: 1, scale: 1, os: os, osVersion: "1", make: "m", model: "m",
                          userAgent: "ua", openRTBDeviceType: 4)
        }
        #expect(device("iOS").platform == .apple && device("iPadOS").platform == .apple)
        #expect(device("Android").platform == .android)
        #expect(device("tvOS").platform == .other && device("Roku OS").platform == .other)
    }
}
