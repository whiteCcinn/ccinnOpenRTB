import CoreGraphics
import RTBKit
@testable import CcinnOpenRTB

/// Synthetic inputs shared by the renderer tests.
enum RendererFixtures {
    static let phone = DeviceProfile(id: "test-phone", name: "Test Phone", family: .iPhone, screenWidth: 390, screenHeight: 844, scale: 3,
                                     safeArea: DeviceInsets(top: 47, bottom: 34), os: "iOS", osVersion: "18.0", make: "Apple",
                                     model: "Test", userAgent: "TestUA/1.0", openRTBDeviceType: 4)
    static let tv = DeviceProfile(id: "test-tv", name: "Test TV", family: .ctv, screenWidth: 1920, screenHeight: 1080, scale: 1, os: "tvOS",
                                  osVersion: "18.0", make: "Apple", model: "TV", userAgent: "TVUA/1.0", openRTBDeviceType: 3, input: .remote,
                                  supportsClickThrough: false)
    static let foldable = DeviceProfile(id: "test-fold", name: "Fold", family: .foldable, screenWidth: 600, screenHeight: 800, scale: 2,
                                        foldedWidth: 360, foldedHeight: 780, os: "Android", osVersion: "14", make: "G", model: "F",
                                        userAgent: "UA", openRTBDeviceType: 4)
    static let duo = DeviceProfile(id: "test-duo", name: "Duo", family: .dualScreen, screenWidth: 540, screenHeight: 720, scale: 2,
                                   hingeWidth: 34, os: "Android", osVersion: "14", make: "M", model: "D", userAgent: "UA",
                                   openRTBDeviceType: 4)

    static func candidate(_ markup: AdMarkup, format: AdFormat = .banner, bundle: String? = nil) -> AdCandidate {
        AdCandidate(id: "0.0", bidID: "bid-1", price: 1.5, bundle: bundle, size: AdSize(width: 320, height: 50), format: format, markup: markup)
    }

    static func request(_ markup: AdMarkup, format: AdFormat = .banner, native: NativeAd? = nil, vast: ResolvedVAST? = nil,
                        device: DeviceProfile = phone, placement: Placement = .inlineBanner, landscape: Bool = false,
                        adSize: CGSize = CGSize(width: 320, height: 50), visibleFraction: Double = 1) -> RenderRequest {
        RenderRequest(candidate: candidate(markup, format: format), native: native, vast: vast, device: device, placement: placement,
                      landscape: landscape, spanned: false, folded: false, adSize: adSize, visibleFraction: visibleFraction, generation: 0)
    }

    static func linearAd(duration: Double = 15, media: [VASTMediaFile] = [VASTMediaFile(url: "https://cdn.example/a.mp4", type: "video/mp4")],
                         skipOffset: VASTOffset? = nil, clickThrough: String? = "https://adv.example/landing",
                         tracking: [VASTTracking] = [], companions: [VASTCompanion] = [], sequence: Int? = nil) -> ResolvedVASTAd {
        let linear = VASTLinear(duration: duration, skipOffset: skipOffset, mediaFiles: media, trackingEvents: tracking, clickThrough: clickThrough)
        let inline = VASTInline(adSystem: "Test", adTitle: "Ad", impressions: ["https://t.example/imp"],
                                creatives: [VASTCreative(sequence: 1, linear: linear, companions: companions)])
        return ResolvedVASTAd(inline: inline, sequence: sequence, impressions: inline.impressions, trackingEvents: tracking)
    }
}
