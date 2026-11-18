import Foundation
import RTBKit

/// A rectangle in device points, as MRAID reports it.
struct MRAIDRect: Equatable, Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct MRAIDSize: Equatable, Codable, Sendable {
    var width: Double
    var height: Double
}

/// Everything the MRAID shim needs to answer its getters, derived from the render request (pure).
struct MRAIDEnvironment: Equatable, Codable, Sendable {
    var version = "3.0"
    /// `inline` or `interstitial`.
    var placementType: String
    var screenSize: MRAIDSize
    var maxSize: MRAIDSize
    /// Relative to the max-size area: an inline ad at its top, centred horizontally; an interstitial centred.
    var defaultPosition: MRAIDRect
    /// 0…100.
    var exposedPercentage: Double
    var orientation: String
    var supports: [String: Bool]
    /// MRAID 3.0 `MRAID_ENV`.
    var sdk = "CcinnOpenRTB"
    var sdkVersion = "1.0.0"
    var appID: String?
    /// Banner placements must not scroll.
    var disableScroll: Bool

    static let supportedFeatures: [String: Bool] = [
        "sms": false, "tel": false, "calendar": false, "storePicture": false, "inlineVideo": true, "vpaid": false, "location": false,
    ]

    init(request: RenderRequest) {
        let device = request.device
        let screen = Self.screenSize(request)
        let insets = Self.insets(device: device, landscape: request.landscape)
        let interstitial = Self.isInterstitial(request.placement)
        let maxSize = MRAIDSize(width: max(0, screen.width - insets.leading - insets.trailing),
                                height: max(0, screen.height - insets.top - insets.bottom))
        let adWidth = Self.clean(request.adSize.width)
        let adHeight = Self.clean(request.adSize.height)
        // MRAID positions are offsets from the top-left corner of the getMaxSize() area (the safe area).
        let x = max(0, (maxSize.width - adWidth) / 2)
        let y = interstitial ? max(0, (maxSize.height - adHeight) / 2) : 0
        placementType = interstitial ? "interstitial" : "inline"
        screenSize = screen
        self.maxSize = maxSize
        defaultPosition = MRAIDRect(x: x.rounded(), y: y.rounded(), width: adWidth, height: adHeight)
        exposedPercentage = Self.percentage(request.visibleFraction)
        orientation = request.landscape ? "landscape" : "portrait"
        supports = Self.supportedFeatures
        // MRAID 3.0 §3.2: the publisher's app, never the advertiser's bid.bundle.
        appID = request.publisherAppBundle ?? request.placement.simulatedAppBundle
        disableScroll = !interstitial
    }

    static func isInterstitial(_ placement: Placement) -> Bool {
        switch placement {
        case .interstitial, .rewarded, .ctvInstream: true
        case .inlineBanner, .inFeed: false
        }
    }

    /// Visible fraction → MRAID exposure percentage (0…100, finite).
    static func percentage(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return (min(1, max(0, fraction)) * 1000).rounded() / 10
    }

    /// The screen the ad lives on, oriented: the folded cover screen, both screens plus the hinge when spanned.
    static func screenSize(_ request: RenderRequest) -> MRAIDSize {
        let device = request.device
        var width = device.screenWidth
        var height = device.screenHeight
        if request.folded, let foldedWidth = device.foldedWidth, let foldedHeight = device.foldedHeight {
            width = foldedWidth
            height = foldedHeight
        }
        if request.spanned, let hinge = device.hingeWidth {
            width = width * 2 + hinge
        }
        // CTV profiles are already landscape; phones are stored portrait.
        if request.landscape, width < height {
            swap(&width, &height)
        }
        return MRAIDSize(width: clean(width), height: clean(height))
    }

    /// Safe-area insets rotated for landscape (the top inset moves to the leading edge).
    static func insets(device: DeviceProfile, landscape: Bool) -> DeviceInsets {
        let safe = device.safeArea
        guard landscape, device.family != .ctv else { return safe }
        return DeviceInsets(top: 0, leading: safe.top, bottom: min(safe.bottom, 21), trailing: safe.top)
    }

    private static func clean(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
