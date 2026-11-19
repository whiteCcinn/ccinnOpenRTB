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
    /// `navigator.vendor`: Apple's for WebKit, Google's for Chrome.
    var vendor: String
    /// Chrome's User-Agent Client Hints, when the browser is Chrome (or an Android WebView): `navigator.userAgentData`
    /// and the `Sec-CH-UA*` headers bidders read for the device (Prebid's `device.sua`).
    var chrome: ChromeHints?

    struct ChromeHints: Sendable, Hashable {
        var major: Int
        /// "Google Chrome", or "Android WebView" in an app.
        var brand: String
        var mobile: Bool
        var platform: String
        var platformVersion: String
        var model: String

        /// `navigator.userAgentData.brands`, in Chrome's order.
        var brands: [(brand: String, version: String)] {
            [("Chromium", "\(major)"), (brand, "\(major)"), ("Not_A Brand", "24")]
        }

        /// The low-entropy hints Chrome sends on every https request.
        var headers: [String: String] {
            ["Sec-CH-UA": brands.map { "\"\($0.brand)\";v=\"\($0.version)\"" }.joined(separator: ", "),
             "Sec-CH-UA-Mobile": mobile ? "?1" : "?0", "Sec-CH-UA-Platform": "\"\(platform)\""]
        }

    }

    /// The languages of the monitor's `Accept-Language: en-US,en;q=0.9`.
    static let languages = ["en-US", "en"]

    init(screenWidth: Int, screenHeight: Int, viewportWidth: Int, viewportHeight: Int, pixelRatio: Double, platform: String,
         maxTouchPoints: Int, languages: [String] = PrebidDevice.languages, vendor: String = "Apple Computer, Inc.", chrome: ChromeHints? = nil) {
        self.vendor = vendor
        self.chrome = chrome
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
        let chrome = Self.chromeHints(userAgent: userAgent, device: device)
        self.init(screenWidth: width, screenHeight: height, viewportWidth: width, viewportHeight: max(1, height - bars),
                  pixelRatio: device.scale, platform: Self.platform(forUserAgent: userAgent), maxTouchPoints: device.input == .touch ? 5 : 0,
                  vendor: chrome != nil ? "Google Inc." : (userAgent.contains("Firefox/") ? "" : "Apple Computer, Inc."), chrome: chrome)
    }

    /// Chrome's hints for a Chrome or Android WebView User-Agent (`Chrome/157.0.0.0`); `nil` for any other browser.
    static func chromeHints(userAgent: String, device: DeviceProfile) -> ChromeHints? {
        guard let range = userAgent.range(of: "Chrome/"), !userAgent.contains("Edg/") else { return nil }
        let digits = userAgent[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard let major = Int(digits), major > 0 else { return nil }
        let android = userAgent.contains("Android")
        return ChromeHints(major: major, brand: userAgent.contains("; wv)") ? "Android WebView" : "Google Chrome",
                           mobile: userAgent.contains("Mobile"), platform: android ? "Android" : Self.platform(forUserAgent: userAgent),
                           platformVersion: android ? device.osVersion : "", model: android ? device.model : "")
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
