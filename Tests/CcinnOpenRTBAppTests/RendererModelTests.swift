import AppKit
import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

@MainActor
@Suite("Image banner model")
struct ImageBannerModelTests {
    private let banner = ImageBanner(imageURL: "https://cdn.example/banner.png", link: AdLink(url: "https://adv.example/"))

    @Test func aLoadedImageIsRenderedOnceAndClicksAreReported() async {
        let host = RecordingHost()
        host.contents[banner.imageURL] = TestImages.png()
        let model = ImageBannerModel(host: host)
        let request = RendererFixtures.request(.image(banner))
        await model.load(banner, request: request)
        await model.load(banner, request: request)
        #expect(model.image.image != nil)
        #expect(host.events == [.rendered])
        model.click(banner, request: request)
        #expect(host.events == [.rendered, .click(assetID: nil)])
        #expect(host.navigations.isEmpty, "the .click tracking plan records the banner link's navigation")
    }

    @Test func aFailedImageIsNeitherRenderedNorClickable() async {
        let host = RecordingHost()
        let model = ImageBannerModel(host: host)
        let request = RendererFixtures.request(.image(banner))
        await model.load(banner, request: request)
        model.click(banner, request: request)
        #expect(host.events.isEmpty)
        #expect(host.logs.contains { $0.origin == "Display" && $0.level == .error })
        host.contents[banner.imageURL] = Data("not an image".utf8)
        let second = ImageBannerModel(host: host)
        await second.load(banner, request: request)
        #expect(second.image.image == nil)
        #expect(host.events.isEmpty)
    }

    @Test func ctvHasNoClickAndCloseFiresOnce() async {
        let host = RecordingHost(device: RendererFixtures.tv)
        host.contents[banner.imageURL] = TestImages.png()
        let model = ImageBannerModel(host: host)
        let request = RendererFixtures.request(.image(banner), device: RendererFixtures.tv, placement: .interstitial)
        await model.load(banner, request: request)
        model.click(banner, request: request)
        model.close()
        model.close()
        #expect(host.events == [.rendered, .closed])
    }
}

@MainActor
@Suite("Native ad model")
struct NativeAdModelTests {
    private static let ad = NativeAd(
        version: "1.2",
        assets: [
            NativeAsset(id: 1, content: .title(text: "Great App"), typeSource: .response),
            NativeAsset(id: 2, content: .image(url: "https://cdn.example/icon.png", width: 80, height: 80, type: .icon), typeSource: .response),
            NativeAsset(id: 3, content: .image(url: "https://cdn.example/main.png", width: 1200, height: 627, type: .main), typeSource: .response),
            NativeAsset(id: 4, content: .data(value: "Install", label: nil, type: .callToAction),
                        link: AdLink(url: "https://adv.example/cta", clickTrackers: ["https://t.example/cta"]), typeSource: .response),
            NativeAsset(id: 5, content: .video(vastTag: "https://vast.example/tag.xml"), typeSource: .response),
        ],
        link: AdLink(url: "https://adv.example/", clickTrackers: ["https://t.example/click"]),
        privacyURL: "https://privacy.example/")

    @Test func renderedOnceAssetClicksAndAdChoices() async {
        let host = RecordingHost()
        let model = NativeAdModel(ad: Self.ad, request: RendererFixtures.request(.native("{}"), format: .native, native: Self.ad,
                                                                                  placement: .inFeed), host: host)
        model.appeared()
        await model.loadImages()
        model.appeared()
        model.click(assetID: 4)
        model.click(assetID: nil)
        model.openPrivacy()
        #expect(host.events == [.rendered, .click(assetID: 4), .click(assetID: nil)])
        #expect(host.navigations == [.init(url: "https://privacy.example/", trigger: "AdChoices (privacy)")],
                "AdChoices is a navigation, not an ad click; ad clicks navigate through the tracking plan")
    }

    /// AdTech review (decided): a Native ad is rendered — impression trackers, billing — when its main assets (the main
    /// image and the icon) have loaded or failed, not as soon as its view appears and before the images are requested;
    /// at most 1 s after it appears.
    @Test func renderedOnlyOnceTheMainImagesHaveLoadedOrFailed() async {
        let host = RecordingHost()
        host.contents["https://cdn.example/icon.png"] = TestImages.png(width: 8, height: 8)
        let model = NativeAdModel(ad: Self.ad, request: RendererFixtures.request(.native("{}"), format: .native, native: Self.ad), host: host)
        model.appeared()
        #expect(host.events.isEmpty, "the images are not even requested yet")
        await model.loadImages()
        #expect(host.events == [.rendered], "icon loaded, main image failed: both settled")
    }

    @Test func renderedAfterOneSecondWhenTheImagesHang() async {
        let host = RecordingHost()
        host.fetchDelay = .seconds(30)
        let model = NativeAdModel(ad: Self.ad, request: RendererFixtures.request(.native("{}"), format: .native, native: Self.ad), host: host)
        model.appeared()
        let loading = Task { await model.loadImages() }
        defer { loading.cancel() }
        #expect(!(await Wait.until(timeout: .milliseconds(700)) { !host.events.isEmpty }), "not before the cap")
        // The cap is 1 s; the hung images would take 30 s. The bound only guards against that (a loaded 3-core CI runner
        // needed more than 2 s to run the 1 s timer).
        #expect(await Wait.until(timeout: .seconds(15)) { host.events == [.rendered] }, "\(host.events)")
    }

    @Test func aNativeAdWithoutImagesIsRenderedWhenItAppears() {
        let host = RecordingHost()
        let ad = NativeAd(assets: [NativeAsset(id: 1, content: .title(text: "Text only"))], link: AdLink(url: "https://adv.example/"))
        let model = NativeAdModel(ad: ad, request: RendererFixtures.request(.native("{}"), format: .native, native: ad), host: host)
        model.appeared()
        #expect(host.events == [.rendered])
    }

    @Test func imagesLoadThroughTheHostAndFailuresAreLogged() async {
        let host = RecordingHost()
        host.contents["https://cdn.example/icon.png"] = TestImages.png(width: 8, height: 8)
        let model = NativeAdModel(ad: Self.ad, request: RendererFixtures.request(.native("{}"), format: .native, native: Self.ad), host: host)
        await model.loadImages()
        #expect(model.images[2]?.image != nil)
        if case .failed = model.images[3] {} else { Issue.record("the missing main image is a failure: \(String(describing: model.images[3]))") }
        #expect(host.logs.contains { $0.origin == "Native" && $0.message.contains("asset 3") })
    }

    @Test func theVideoAssetIsResolvedByTheHost() async {
        let host = RecordingHost()
        let model = NativeAdModel(ad: Self.ad, request: RendererFixtures.request(.native("{}"), format: .native, native: Self.ad), host: host)
        await model.resolveVideo()
        #expect(host.resolvedSources == [.url("https://vast.example/tag.xml")])
        #expect(model.video == .unavailable("the VAST has no ad"))
        host.vastResolution = ResolvedVAST(ads: [RendererFixtures.linearAd()])
        let second = NativeAdModel(ad: Self.ad, request: RendererFixtures.request(.native("{}"), format: .native, native: Self.ad), host: host)
        await second.resolveVideo()
        await second.resolveVideo()
        #expect(host.resolvedSources.count == 2, "resolved once per model")
        #expect(second.video == .ready(host.vastResolution))
    }

    @Test func ctvDisablesClicksAndPrivacy() {
        let host = RecordingHost(device: RendererFixtures.tv)
        let model = NativeAdModel(ad: Self.ad, request: RendererFixtures.request(.native("{}"), format: .native, native: Self.ad,
                                                                                  device: RendererFixtures.tv, placement: .ctvInstream), host: host)
        model.click(assetID: 4)
        model.openPrivacy()
        #expect(host.events.isEmpty)
        #expect(host.navigations.isEmpty)
    }

    @Test func vastTagsBecomeSources() {
        func source(_ tag: String) -> VASTSource { NativeVideoItem(assetID: 1, vastTag: tag).vastSource }
        #expect(source("  <VAST version=\"4.0\"></VAST> ") == .xml(#"<VAST version="4.0"></VAST>"#))
        #expect(source("https://vast.example/tag?a=1") == .url("https://vast.example/tag?a=1"))
        #expect(source("ccinn-sample://media/sample-15s.mp4") == .url("ccinn-sample://media/sample-15s.mp4"))
        #expect(source("data:text/xml,<VAST/>") == .url("data:text/xml,<VAST/>"))
        #expect(source("not a url") == .xml("not a url"))
    }
}

@MainActor
@Suite("VAST player configuration")
struct VASTPlayerConfigurationTests {
    @Test func theAdAndANativeVideoAssetDiffer() {
        let request = RendererFixtures.request(.vast(.xml("<VAST/>")), format: .video, placement: .inFeed)
        let ad = VASTPlayerConfiguration(request: request, role: .ad(audioOnly: false), playerSize: CGSize(width: 320, height: 180))
        #expect(ad.reportsRendered && ad.showsCompanions && !ad.audioOnly)
        #expect(ad.source == "bid 0.0 › VAST")
        #expect(ad.startsMuted, "in-feed video autoplays muted")
        let native = VASTPlayerConfiguration(request: request, role: .nativeVideo(assetID: 5), playerSize: CGSize(width: 320, height: 180))
        #expect(!native.reportsRendered && !native.showsCompanions)
        #expect(native.source == "bid 0.0 › native › asset 5 (video) › VAST")
        let audio = VASTPlayerConfiguration(request: request, role: .ad(audioOnly: true), playerSize: .zero)
        #expect(audio.audioOnly && !audio.startsMuted)
    }

    @Test func ctvHasNoClickThroughAndRewardedNoSkip() {
        let tv = RendererFixtures.request(.vast(.xml("<VAST/>")), format: .video, device: RendererFixtures.tv, placement: .ctvInstream)
        let ctv = VASTPlayerConfiguration(request: tv, role: .ad(audioOnly: false), playerSize: CGSize(width: 1920, height: 1080))
        #expect(ctv.isCTV && !ctv.allowsClickThrough)
        let rewarded = VASTPlayerConfiguration(request: RendererFixtures.request(.vast(.xml("<VAST/>")), format: .video, placement: .rewarded),
                                               role: .ad(audioOnly: false), playerSize: .zero)
        #expect(!rewarded.skipEnabled)
    }
}
