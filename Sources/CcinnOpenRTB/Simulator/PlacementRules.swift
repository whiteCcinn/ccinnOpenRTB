import RTBKit

/// Simulator rules for placements (the enum itself is part of the renderer contract).
extension Placement {
    /// The ad covers the whole screen in use.
    var isFullScreen: Bool {
        switch self {
        case .interstitial, .rewarded, .ctvInstream: true
        case .inlineBanner, .inFeed: false
        }
    }

    var systemImage: String {
        switch self {
        case .inlineBanner: "rectangle.bottomhalf.inset.filled"
        case .inFeed: "list.bullet.rectangle"
        case .interstitial: "rectangle.inset.filled"
        case .rewarded: "gift"
        case .ctvInstream: "play.tv"
        }
    }

    /// CTV only plays instream; touch devices offer the app placements.
    static func available(on device: DeviceProfile) -> [Placement] {
        device.family == .ctv ? [.ctvInstream] : [.inlineBanner, .inFeed, .interstitial, .rewarded]
    }

    /// The placement a bid of `format` most likely targets on `device`. The bid's impression in the request, when known,
    /// names its ad unit first: rewarded, then interstitial (`imp.rwdd`, `imp.instl`, …); CTV only plays instream.
    static func suggested(for format: AdFormat?, size: AdSize?, on device: DeviceProfile,
                          impression: BidRequestSummary.Impression? = nil) -> Placement {
        if device.family == .ctv { return .ctvInstream }
        if impression?.isRewarded == true { return .rewarded }
        if impression?.isInterstitial == true { return .interstitial }
        switch format {
        case .native?: return .inFeed
        case .video?, .audio?: return .interstitial
        case .banner?, nil:
            if let size, isInterstitialSize(size) { return .interstitial }
            return .inlineBanner
        }
    }

    /// The IAB full-screen sizes (320×480, 480×320, 768×1024, 1024×768) and anything at least that large.
    private static func isInterstitialSize(_ size: AdSize) -> Bool {
        let short = min(size.width, size.height)
        let long = max(size.width, size.height)
        return short >= 320 && long >= 480
    }

    /// `self` when it can run on `device`, else the suggestion for `format` (and the bid's impression).
    func compatible(with device: DeviceProfile, format: AdFormat?, size: AdSize?, impression: BidRequestSummary.Impression? = nil) -> Placement {
        Self.available(on: device).contains(self) ? self : Self.suggested(for: format, size: size, on: device, impression: impression)
    }
}
