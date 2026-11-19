import Foundation
import RTBKit

/// The simulated device as the Prebid page's scripts read it (`screen`, `innerWidth`, `devicePixelRatio`,
/// `navigator.platform` …), so bidders see the phone and not the Mac. The platform follows the User-Agent the page sends,
/// so the two never disagree. Pure.
struct PrebidDevice: Sendable, Hashable {
    var screenWidth: Int
    var screenHeight: Int
    /// The layout viewport: the screen less the system bars (the browser's own bars are not modelled).
    var viewportWidth: Int
    var viewportHeight: Int
    var pixelRatio: Double
    var platform: String
    var maxTouchPoints: Int
    var languages: [String]

    /// The languages of the monitor's `Accept-Language: en-US,en;q=0.9`.
    static let languages = ["en-US", "en"]

    init(screenWidth: Int, screenHeight: Int, viewportWidth: Int, viewportHeight: Int, pixelRatio: Double, platform: String,
         maxTouchPoints: Int, languages: [String] = PrebidDevice.languages) {
        self.screenWidth = max(1, screenWidth)
        self.screenHeight = max(1, screenHeight)
        self.viewportWidth = max(1, viewportWidth)
        self.viewportHeight = max(1, viewportHeight)
        self.pixelRatio = pixelRatio.isFinite && pixelRatio > 0 ? pixelRatio : 1
        self.platform = platform
        self.maxTouchPoints = max(0, maxTouchPoints)
        self.languages = languages.isEmpty ? PrebidDevice.languages : languages
    }

    init(device: DeviceProfile, userAgent: String) {
        let width = Self.points(device.screenWidth)
        let height = Self.points(device.screenHeight)
        let bars = Self.points(device.safeArea.top + device.safeArea.bottom)
        self.init(screenWidth: width, screenHeight: height, viewportWidth: width, viewportHeight: max(1, height - bars),
                  pixelRatio: device.scale, platform: Self.platform(forUserAgent: userAgent), maxTouchPoints: device.input == .touch ? 5 : 0)
    }

    /// `navigator.platform` of the browser that sends `userAgent`.
    static func platform(forUserAgent userAgent: String) -> String {
        if userAgent.contains("iPhone") { return "iPhone" }
        if userAgent.contains("iPad") { return "iPad" }
        if userAgent.contains("Android") { return "Linux armv81" }
        if userAgent.contains("Macintosh") { return "MacIntel" }
        if userAgent.contains("Windows") { return "Win32" }
        return userAgent.contains("Linux") || userAgent.contains("Tizen") || userAgent.contains("Web0S") ? "Linux armv7l" : ""
    }

    private static func points(_ value: Double) -> Int {
        guard value.isFinite else { return 1 }
        return Int(min(max(value.rounded(), 1), 100_000))
    }
}
