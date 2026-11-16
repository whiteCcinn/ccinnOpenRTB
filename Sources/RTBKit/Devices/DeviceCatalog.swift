import Foundation

/// Built-in devices (design D8). Owner: app-shell.
///
/// Sources and conventions:
/// - **Screen sizes** are logical points (iOS) or density-independent pixels (Android) as reported to web content, i.e.
///   what `window.innerWidth`/`screen.width` returns and what an SDK puts in `device.w`/`device.h` after dividing by
///   `pxratio`. Apple values come from Apple's Human Interface Guidelines ("Layout › Specifications"). Android values
///   are the panel resolution from the maker's spec sheet divided by the default density; where that density is an
///   assumption it says so and the value is marked **approx.**
/// - **Corner radii and safe areas** for iPhones are the values UIKit reports (`safeAreaInsets`, and the display corner
///   radius measured by the developer community); Android values are **approx.** (status bar / gesture bar heights vary
///   by OEM skin and font scale).
/// - **User-Agents** are the in-app forms an ad SDK sends: the `WKWebView` UA on iOS/iPadOS (no `Version/… Safari/…`
///   suffix), the Android System WebView UA (`; wv`), and the media-stack UA on TV platforms (AppleCoreMedia, Dalvik,
///   Roku DVP). Build identifiers inside them follow the real format but are illustrative, not tied to a release.
/// - **`openRTBDeviceType`** follows AdCOM "Device Types": 4 phone, 5 tablet, 3 connected TV (a TV set with the platform
///   built in), 7 set-top box (a box or stick plugged into a TV).
/// - **CTV** devices use a 1920×1080 pt canvas (the size players and bid requests use for full-screen video); 4K
///   devices render it at scale 2. CTV is landscape only, driven by a remote, and cannot open click-throughs.
public enum DeviceCatalog {
    /// Devices of one family, in catalog order.
    public struct Group: Sendable, Hashable, Identifiable {
        public var family: DeviceProfile.Family
        public var devices: [DeviceProfile]
        public var id: DeviceProfile.Family { family }
    }

    public static let all: [DeviceProfile] = iPhones + androidPhones + foldables + dualScreens + tablets + connectedTVs

    /// `all`, grouped by family in `DeviceProfile.Family.allCases` order (for grouped device pickers).
    public static let groups: [Group] = DeviceProfile.Family.allCases.compactMap { family in
        let devices = all.filter { $0.family == family }
        return devices.isEmpty ? nil : Group(family: family, devices: devices)
    }

    public static var defaultDevice: DeviceProfile { iPhone15Pro }

    public static func device(id: String) -> DeviceProfile? { all.first { $0.id == id } }

    // MARK: - iPhone

    /// iOS 18.6: every iPhone below runs it, and Safari/WKWebView keep reporting `18_6` in the UA on later releases.
    private static let iOSVersion = "18.6"
    private static let iOSVersionToken = iOSVersion.replacingOccurrences(of: ".", with: "_")

    private static let iPhoneUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS \(iOSVersionToken) like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    private static func iPhone(_ id: String, _ name: String, model: String, width: Double, height: Double, scale: Double,
                               cornerRadius: Double, safeArea: DeviceInsets, cutout: DeviceProfile.Cutout) -> DeviceProfile {
        DeviceProfile(id: id, name: name, family: .iPhone, screenWidth: width, screenHeight: height, scale: scale, cornerRadius: cornerRadius,
                      safeArea: safeArea, cutout: cutout, os: "iOS", osVersion: iOSVersion, make: "Apple", model: model,
                      userAgent: iPhoneUserAgent, openRTBDeviceType: 4)
    }

    // HIG: 393×852 pt @3x (2556×1179 px). Dynamic Island; safe area 59/34 pt; display corner radius 55 pt.
    private static let iPhone15Pro = iPhone("iphone-15-pro", "iPhone 15 Pro", model: "iPhone16,1", width: 393, height: 852, scale: 3,
                                            cornerRadius: 55, safeArea: DeviceInsets(top: 59, bottom: 34), cutout: .dynamicIsland)

    private static let iPhones: [DeviceProfile] = [
        // HIG: 375×667 pt @2x (1334×750 px). Rectangular LCD with a Touch ID home button: 20 pt status bar, no bottom inset.
        iPhone("iphone-se-3", "iPhone SE (3rd gen)", model: "iPhone14,6", width: 375, height: 667, scale: 2, cornerRadius: 0,
               safeArea: DeviceInsets(top: 20), cutout: .none),
        // HIG: 375×812 pt @3x (2340×1080 px). Notch; safe area 50/34 pt; display corner radius 44 pt.
        iPhone("iphone-13-mini", "iPhone 13 mini", model: "iPhone14,4", width: 375, height: 812, scale: 3, cornerRadius: 44,
               safeArea: DeviceInsets(top: 50, bottom: 34), cutout: .notch),
        // HIG: 393×852 pt @3x (2556×1179 px). Dynamic Island; safe area 59/34 pt; display corner radius 55 pt.
        iPhone("iphone-15", "iPhone 15", model: "iPhone15,4", width: 393, height: 852, scale: 3, cornerRadius: 55,
               safeArea: DeviceInsets(top: 59, bottom: 34), cutout: .dynamicIsland),
        // HIG: 430×932 pt @3x (2796×1290 px). Dynamic Island; safe area 59/34 pt; display corner radius 55 pt.
        iPhone("iphone-15-plus", "iPhone 15 Plus", model: "iPhone15,5", width: 430, height: 932, scale: 3, cornerRadius: 55,
               safeArea: DeviceInsets(top: 59, bottom: 34), cutout: .dynamicIsland),
        iPhone15Pro,
        // Same geometry as iPhone 15 Plus.
        iPhone("iphone-15-pro-max", "iPhone 15 Pro Max", model: "iPhone16,2", width: 430, height: 932, scale: 3, cornerRadius: 55,
               safeArea: DeviceInsets(top: 59, bottom: 34), cutout: .dynamicIsland),
        // HIG: 402×874 pt @3x (2622×1206 px). Thinner borders: safe area 62/34 pt; display corner radius 62 pt.
        iPhone("iphone-16-pro", "iPhone 16 Pro", model: "iPhone17,1", width: 402, height: 874, scale: 3, cornerRadius: 62,
               safeArea: DeviceInsets(top: 62, bottom: 34), cutout: .dynamicIsland),
        // HIG: 440×956 pt @3x (2868×1320 px). Safe area 62/34 pt; display corner radius 62 pt. (iPhone 17 Pro Max: same size.)
        iPhone("iphone-16-pro-max", "iPhone 16 Pro Max", model: "iPhone17,2", width: 440, height: 956, scale: 3, cornerRadius: 62,
               safeArea: DeviceInsets(top: 62, bottom: 34), cutout: .dynamicIsland),
    ]

    // MARK: - Android

    /// Android System WebView UA as sent by in-app ad SDKs.
    private static func androidWebViewUserAgent(android: String, model: String, build: String) -> String {
        "Mozilla/5.0 (Linux; Android \(android); \(model) Build/\(build); wv) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Version/4.0 Chrome/129.0.6668.81 Mobile Safari/537.36"
    }

    private static let androidPhones: [DeviceProfile] = [
        // Google spec: 1080×2400 px at 420 dpi (2.625) → 411.4×914.3 dp; Chrome reports 412×915. Centred punch-hole camera.
        // Corner radius, status bar 28 dp and gesture bar 24 dp: approx.
        DeviceProfile(id: "pixel-8", name: "Pixel 8", family: .androidPhone, screenWidth: 412, screenHeight: 915, scale: 2.625,
                      cornerRadius: 34, safeArea: DeviceInsets(top: 28, bottom: 24), cutout: .punchHole, os: "Android", osVersion: "14",
                      make: "Google", model: "Pixel 8",
                      userAgent: androidWebViewUserAgent(android: "14", model: "Pixel 8", build: "AP2A.240905.003"), openRTBDeviceType: 4),
        // Samsung spec: 1080×2340 px; default density 480 dpi (3.0) → 360×780 dp. Centred punch-hole. Corner radius, insets approx.
        DeviceProfile(id: "galaxy-s24", name: "Galaxy S24", family: .androidPhone, screenWidth: 360, screenHeight: 780, scale: 3,
                      cornerRadius: 30, safeArea: DeviceInsets(top: 28, bottom: 24), cutout: .punchHole, os: "Android", osVersion: "14",
                      make: "Samsung", model: "SM-S921B",
                      userAgent: androidWebViewUserAgent(android: "14", model: "SM-S921B", build: "UP1A.231005.007"), openRTBDeviceType: 4),
    ]

    // MARK: - Foldables

    private static let foldables: [DeviceProfile] = [
        // Galaxy Z Fold5 (Samsung spec): main 2176×1812 px (1812 wide when held as a book), cover 2316×904 px. In points at
        // 2.625: main 690×829, cover 344×882. Approx.: the density is an assumption (Chrome's Fold cover preset is 344×882).
        // Main screen: under-display camera (no visible cutout); cover screen: centred punch-hole.
        DeviceProfile(id: "galaxy-z-fold", name: "Galaxy Z Fold5", family: .foldable, screenWidth: 690, screenHeight: 829, scale: 2.625,
                      cornerRadius: 22, safeArea: DeviceInsets(top: 28, bottom: 24), cutout: .punchHole, foldedWidth: 344, foldedHeight: 882,
                      os: "Android", osVersion: "14", make: "Samsung", model: "SM-F946B",
                      userAgent: androidWebViewUserAgent(android: "14", model: "SM-F946B", build: "UP1A.231005.007"), openRTBDeviceType: 4),
        // Pixel Fold (Google spec): inner 2208×1840 px (wider than tall when unfolded, hinge vertical), outer 2092×1080 px.
        // In points at 2.625: inner 841×701, cover 411×797. Approx.: density assumed. The inner camera sits in the bezel.
        DeviceProfile(id: "pixel-fold", name: "Pixel Fold", family: .foldable, screenWidth: 841, screenHeight: 701, scale: 2.625,
                      cornerRadius: 24, safeArea: DeviceInsets(top: 28, bottom: 24), cutout: .punchHole, foldedWidth: 411, foldedHeight: 797,
                      os: "Android", osVersion: "14", make: "Google", model: "Pixel Fold",
                      userAgent: androidWebViewUserAgent(android: "14", model: "Pixel Fold", build: "AP2A.240905.003"), openRTBDeviceType: 4),
    ]

    // MARK: - Dual-screen

    private static let dualScreens: [DeviceProfile] = [
        // Surface Duo (Microsoft dual-screen docs): each screen 1350×1800 px at 2.5 → 540×720; spanned viewport 1114×720,
        // i.e. a 34 px hinge between the screens. Screen corner radius and insets approx.
        DeviceProfile(id: "surface-duo", name: "Surface Duo", family: .dualScreen, screenWidth: 540, screenHeight: 720, scale: 2.5,
                      cornerRadius: 6, safeArea: DeviceInsets(top: 24, bottom: 24), cutout: .none, hingeWidth: 34,
                      os: "Android", osVersion: "11", make: "Microsoft", model: "Surface Duo",
                      userAgent: androidWebViewUserAgent(android: "11", model: "Surface Duo", build: "2022.902.26"), openRTBDeviceType: 4),
    ]

    // MARK: - Tablets

    /// SDKs report the mobile iPad form (the default WKWebView content mode would send the desktop Mac UA instead).
    private static let iPadUserAgent = "Mozilla/5.0 (iPad; CPU OS \(iOSVersionToken) like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    private static let tablets: [DeviceProfile] = [
        // HIG: 820×1180 pt @2x (2360×1640 px). 24 pt status bar, 20 pt home indicator; display corner radius 18 pt.
        DeviceProfile(id: "ipad-10", name: "iPad (10th gen)", family: .tablet, screenWidth: 820, screenHeight: 1180, scale: 2, cornerRadius: 18,
                      safeArea: DeviceInsets(top: 24, bottom: 20), os: "iPadOS", osVersion: iOSVersion, make: "Apple", model: "iPad13,18",
                      userAgent: iPadUserAgent, openRTBDeviceType: 5),
        // HIG: 834×1194 pt @2x (2388×1668 px), iPad Pro 11-inch (1st–4th gen). Same insets and corner radius as above.
        DeviceProfile(id: "ipad-pro-11", name: "iPad Pro 11\"", family: .tablet, screenWidth: 834, screenHeight: 1194, scale: 2, cornerRadius: 18,
                      safeArea: DeviceInsets(top: 24, bottom: 20), os: "iPadOS", osVersion: iOSVersion, make: "Apple", model: "iPad14,3",
                      userAgent: iPadUserAgent, openRTBDeviceType: 5),
    ]

    // MARK: - Connected TV

    private static func tv(_ id: String, _ name: String, scale: Double, os: String, osVersion: String, make: String, model: String,
                           userAgent: String, deviceType: Int) -> DeviceProfile {
        DeviceProfile(id: id, name: name, family: .ctv, screenWidth: 1920, screenHeight: 1080, scale: scale, os: os, osVersion: osVersion,
                      make: make, model: model, userAgent: userAgent, openRTBDeviceType: deviceType, input: .remote, supportsClickThrough: false)
    }

    private static let connectedTVs: [DeviceProfile] = [
        // tvOS lays out 1920×1080 pt; the 4K model renders @2x. A box → set-top box (7). AVPlayer's AppleCoreMedia UA.
        tv("apple-tv-4k", "Apple TV 4K", scale: 2, os: "tvOS", osVersion: "18.0", make: "Apple", model: "AppleTV14,1",
           userAgent: "AppleCoreMedia/1.0.0.22J357 (Apple TV; U; CPU OS 18_0 like Mac OS X; en_us)", deviceType: 7),
        // A 4K TV set with Google TV built in → connected TV (3). ExoPlayer-based apps send the Dalvik UA. Model name approx.
        tv("google-tv", "Google TV (4K TV)", scale: 2, os: "Android", osVersion: "12", make: "Sony", model: "BRAVIA 4K VH2",
           userAgent: "Dalvik/2.1.0 (Linux; U; Android 12; BRAVIA 4K VH2 Build/STT2.230817.001.S4)", deviceType: 3),
        // Fire TV Stick 4K Max (model code AFTKA, Fire OS 7 on Android 9) → set-top box (7).
        tv("fire-tv-stick-4k", "Fire TV Stick 4K Max", scale: 2, os: "Fire OS", osVersion: "7.6", make: "Amazon", model: "AFTKA",
           userAgent: "Dalvik/2.1.0 (Linux; U; Android 9; AFTKA Build/PS7633.3445N)", deviceType: 7),
        // Roku Express: a 1080p player → set-top box (7). roUrlTransfer's default `Roku/DVP-<os> (<build>)` UA. Model code approx.
        tv("roku-express", "Roku Express (1080p)", scale: 1, os: "Roku OS", osVersion: "13.0", make: "Roku", model: "3960X",
           userAgent: "Roku/DVP-13.0 (13.0.0.4170-46)", deviceType: 7),
    ]
}
