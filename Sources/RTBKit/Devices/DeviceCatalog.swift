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
/// - **Current Apple models** (2025–2026: iPhone 16e, 17, Air, 17 Pro/Pro Max, 18 Pro/Pro Max, iPhone Duo, iPad Pro M5)
///   come from Apple's tech specs (pixels ÷ scale) and the safe areas UIKit reports (useyourloaf.com "iPhone 17 Screen
///   Sizes"). Where a value was not published when this catalog was written (iPhone 18 Pro insets, iPhone Duo insets) it
///   is marked **approx.** with what it is based on.
/// - **User-Agents** are the in-app forms an ad SDK sends: the `WKWebView` UA on iOS/iPadOS (no `Version/… Safari/…`
///   suffix; iPads send the desktop-class Macintosh form, as iPadOS does by default), the Android System WebView UA
///   (`; wv`), and the media-stack UA on TV platforms (AppleCoreMedia, Dalvik,
///   Roku DVP). Build identifiers inside them follow the real format but are illustrative, not tied to a release.
/// - **`openRTBDeviceType`** follows AdCOM "Device Types": 4 phone, 5 tablet, 3 connected TV (a TV set with the platform
///   built in), 7 set-top box (a box or stick plugged into a TV). It is reported, never acted on: exchanges disagree on
///   boxes (many send 3 for every CTV device), so nothing in the simulator keys off it.
/// - **CTV** devices use a 1920×1080 pt canvas (the size players and bid requests use for full-screen video); 4K
///   devices render it at scale 2. CTV is landscape only, driven by a remote, and cannot open click-throughs; every one
///   of those behaviours keys off `family == .ctv` (and the `input` / `supportsClickThrough` the catalog sets with it).
/// - **OS versions** are each platform's release as of November 2026; the media-stack User-Agent names the same version
///   as `osVersion`.
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

    /// What a new window simulates, and the device a new Client request goes out as.
    public static var defaultDevice: DeviceProfile { iPhone18Pro }

    public static func device(id: String) -> DeviceProfile? { all.first { $0.id == id } }

    // MARK: - iPhone

    /// iOS / iPadOS 27.2 (November 2026; every Apple phone and tablet below runs it). `device.osv` carries it, but WebKit
    /// froze the OS token of the User-Agent at `18_6` from iOS 26 on, so in-app web views still report `18_6`.
    private static let iOSVersion = "27.2"
    private static let frozenUserAgentOSToken = "18_6"

    private static let iPhoneUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS \(frozenUserAgentOSToken) like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    private static func iPhone(_ id: String, _ name: String, model: String, width: Double, height: Double, scale: Double,
                               cornerRadius: Double, safeArea: DeviceInsets, cutout: DeviceProfile.Cutout) -> DeviceProfile {
        DeviceProfile(id: id, name: name, family: .iPhone, screenWidth: width, screenHeight: height, scale: scale, cornerRadius: cornerRadius,
                      safeArea: safeArea, cutout: cutout, os: "iOS", osVersion: iOSVersion, make: "Apple", model: model,
                      userAgent: iPhoneUserAgent, openRTBDeviceType: 4)
    }

    // Apple: 6.3" 2622×1206 px @3x → 402×874 pt. Dynamic Island; UIKit safe area 62/34 pt (landscape 62 on both sides);
    // display corner radius 62 pt.
    private static let iPhone17Pro = iPhone("iphone-17-pro", "iPhone 17 Pro", model: "iPhone18,1", width: 402, height: 874, scale: 3,
                                            cornerRadius: 62, safeArea: DeviceInsets(top: 62, bottom: 34), cutout: .dynamicIsland)

    // September 2026. Apple: 6.3" 2622×1206 px @3x → 402×874 pt, the 17 Pro size. The Dynamic Island is narrower (Face ID
    // moved under the display: the simulator draws it smaller); safe area approx.: the 17 Pro's 62/34 pt (Apple kept the
    // bezels).
    private static let iPhone18Pro = iPhone("iphone-18-pro", "iPhone 18 Pro", model: "iPhone19,1", width: 402, height: 874, scale: 3,
                                            cornerRadius: 62, safeArea: DeviceInsets(top: 62, bottom: 34), cutout: .dynamicIsland)

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
        // HIG: 393×852 pt @3x (2556×1179 px). Dynamic Island; safe area 59/34 pt; display corner radius 55 pt.
        iPhone("iphone-15-pro", "iPhone 15 Pro", model: "iPhone16,1", width: 393, height: 852, scale: 3, cornerRadius: 55,
               safeArea: DeviceInsets(top: 59, bottom: 34), cutout: .dynamicIsland),
        // Same geometry as iPhone 15 Plus.
        iPhone("iphone-15-pro-max", "iPhone 15 Pro Max", model: "iPhone16,2", width: 430, height: 932, scale: 3, cornerRadius: 55,
               safeArea: DeviceInsets(top: 59, bottom: 34), cutout: .dynamicIsland),
        // HIG: 402×874 pt @3x (2622×1206 px). Thinner borders: safe area 62/34 pt; display corner radius 62 pt.
        iPhone("iphone-16-pro", "iPhone 16 Pro", model: "iPhone17,1", width: 402, height: 874, scale: 3, cornerRadius: 62,
               safeArea: DeviceInsets(top: 62, bottom: 34), cutout: .dynamicIsland),
        // HIG: 440×956 pt @3x (2868×1320 px). Safe area 62/34 pt; display corner radius 62 pt. (iPhone 17 Pro Max: same size.)
        iPhone("iphone-16-pro-max", "iPhone 16 Pro Max", model: "iPhone17,2", width: 440, height: 956, scale: 3, cornerRadius: 62,
               safeArea: DeviceInsets(top: 62, bottom: 34), cutout: .dynamicIsland),
        // Apple: 6.1" 2532×1170 px @3x → 390×844 pt (the iPhone 14 panel). Notch, not an island; safe area 47/34 pt and display
        // corner radius 47.33 pt as on iPhone 14 (approx.: inherited from the same panel).
        iPhone("iphone-16e", "iPhone 16e", model: "iPhone17,5", width: 390, height: 844, scale: 3, cornerRadius: 47.33,
               safeArea: DeviceInsets(top: 47, bottom: 34), cutout: .notch),
        // Apple: 6.3" 2622×1206 px @3x → 402×874 pt, the 17 Pro's panel (ProMotion, Dynamic Island). Safe area 62/34 pt.
        iPhone("iphone-17", "iPhone 17", model: "iPhone18,3", width: 402, height: 874, scale: 3, cornerRadius: 62,
               safeArea: DeviceInsets(top: 62, bottom: 34), cutout: .dynamicIsland),
        // Apple: 6.5" 2736×1260 px @3x → 420×912 pt (a size of its own). Safe area 68/34 pt (landscape 68 on both sides).
        // Display corner radius approx. (as the 6.3"/6.9" models).
        iPhone("iphone-air", "iPhone Air", model: "iPhone18,4", width: 420, height: 912, scale: 3, cornerRadius: 62,
               safeArea: DeviceInsets(top: 68, bottom: 34), cutout: .dynamicIsland),
        iPhone17Pro,
        // Apple: 6.9" 2868×1320 px @3x → 440×956 pt. Safe area 62/34 pt.
        iPhone("iphone-17-pro-max", "iPhone 17 Pro Max", model: "iPhone18,2", width: 440, height: 956, scale: 3, cornerRadius: 62,
               safeArea: DeviceInsets(top: 62, bottom: 34), cutout: .dynamicIsland),
        iPhone18Pro,
        // September 2026. Apple: 6.9" 2868×1320 px @3x → 440×956 pt, the 17 Pro Max size; island and safe area as the 18 Pro.
        iPhone("iphone-18-pro-max", "iPhone 18 Pro Max", model: "iPhone19,2", width: 440, height: 956, scale: 3, cornerRadius: 62,
               safeArea: DeviceInsets(top: 62, bottom: 34), cutout: .dynamicIsland),
    ]

    // MARK: - Android

    /// Android System WebView updates through Google Play apart from the OS, so every Android device runs the current
    /// stable build: 157.0.8103.50 (Chrome Releases, 9 Nov 2026).
    private static let androidWebViewVersion = "157.0.8103.50"

    /// Android System WebView UA as sent by in-app ad SDKs (WebView keeps the model and build that Chrome's reduced UA drops).
    private static func androidWebViewUserAgent(android: String, model: String, build: String) -> String {
        "Mozilla/5.0 (Linux; Android \(android); \(model) Build/\(build); wv) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Version/4.0 Chrome/\(androidWebViewVersion) Mobile Safari/537.36"
    }

    private static let androidPhones: [DeviceProfile] = [
        // Google spec: 1080×2400 px at 420 dpi (2.625) → 411.4×914.3 dp; Chrome reports 412×915. Centred punch-hole camera.
        // Corner radius, status bar 28 dp and gesture bar 24 dp: approx.
        // OS: Android 17, the November 2026 Pixel update, build CP4A.261105.040.A1 (10 Nov 2026, droid-life.com/2026/11/10/
        // 2026-november-pixel-update-download-install-release; Pixels get each release first).
        DeviceProfile(id: "pixel-8", name: "Pixel 8", family: .androidPhone, screenWidth: 412, screenHeight: 915, scale: 2.625,
                      cornerRadius: 34, safeArea: DeviceInsets(top: 28, bottom: 24), cutout: .punchHole, os: "Android", osVersion: "17",
                      make: "Google", model: "Pixel 8",
                      userAgent: androidWebViewUserAgent(android: "17", model: "Pixel 8", build: "CP4A.261105.040.A1"), openRTBDeviceType: 4),
        // Samsung spec: 1080×2340 px; default density 480 dpi (3.0) → 360×780 dp. Centred punch-hole. Corner radius, insets approx.
        // OS: One UI 9.0 = Android 17, stable from October 2026 (Korea first, US carrier models from about 12 Oct; sammobile.com
        // "Galaxy S24 stable One UI 9.0 (Android 17) update is now live"). Samsung follows Google by a few months. The UA's
        // build is the Android 17 base tag (CP2A.260605.016, AOSP 17.0.0); Samsung's own firmware ids are not in the UA.
        DeviceProfile(id: "galaxy-s24", name: "Galaxy S24", family: .androidPhone, screenWidth: 360, screenHeight: 780, scale: 3,
                      cornerRadius: 30, safeArea: DeviceInsets(top: 28, bottom: 24), cutout: .punchHole, os: "Android", osVersion: "17",
                      make: "Samsung", model: "SM-S921B",
                      userAgent: androidWebViewUserAgent(android: "17", model: "SM-S921B", build: "CP2A.260605.016"), openRTBDeviceType: 4),
    ]

    // MARK: - Foldables

    private static let foldables: [DeviceProfile] = [
        // iPhone Duo (September 2026), Apple's book-style foldable: one folding OLED inside, a cover screen outside.
        // - Inner: 7.6" 1878×2670 px at 430 ppi; iOS lays it out at 669×951 pt @3x and downsamples (the simulator and App
        //   Store screenshots are 2007×2853 px). Open, it is wider than tall (951×669) with the fold running vertically;
        //   the front camera is under the display (no cutout). Insets approx.: an iPad-style 24 pt status bar and 20 pt
        //   home indicator (third-party measurements disagree).
        // - Cover: 5.4" 1398×2034 px at 460 ppi → 466×678 pt @3x, with the Dynamic Island; insets approx. as on the
        //   6.1" island iPhones (59/34 pt).
        DeviceProfile(id: "iphone-duo", name: "iPhone Duo", family: .foldable, screenWidth: 951, screenHeight: 669, scale: 3,
                      cornerRadius: 30, safeArea: DeviceInsets(top: 24, bottom: 20), cutout: .dynamicIsland, foldedWidth: 466,
                      foldedHeight: 678, foldedSafeArea: DeviceInsets(top: 59, bottom: 34), os: "iOS", osVersion: iOSVersion,
                      make: "Apple", model: "iPhone19,5", userAgent: iPhoneUserAgent, openRTBDeviceType: 4),
        // Galaxy Z Fold5 (Samsung spec): main 2176×1812 px (1812 wide when held as a book), cover 2316×904 px. In points at
        // 2.625: main 690×829, cover 344×882. Approx.: the density is an assumption (Chrome's Fold cover preset is 344×882).
        // Main screen: under-display camera (no visible cutout); cover screen: centred punch-hole.
        // OS: One UI 9.0 = Android 17, its last major update: Korea 14 Oct, Europe 19 Oct (F946BXXU7HZIJ), US 23 Oct 2026
        // (sammobile.com "Galaxy Z Fold 5, Z Flip 5 get stable One UI 9.0 (Android 17) update"). UA build as for the S24.
        DeviceProfile(id: "galaxy-z-fold", name: "Galaxy Z Fold5", family: .foldable, screenWidth: 690, screenHeight: 829, scale: 2.625,
                      cornerRadius: 22, safeArea: DeviceInsets(top: 28, bottom: 24), cutout: .punchHole, foldedWidth: 344, foldedHeight: 882,
                      os: "Android", osVersion: "17", make: "Samsung", model: "SM-F946B",
                      userAgent: androidWebViewUserAgent(android: "17", model: "SM-F946B", build: "CP2A.260605.016"), openRTBDeviceType: 4),
        // Pixel Fold (Google spec): inner 2208×1840 px (wider than tall when unfolded, hinge vertical), outer 2092×1080 px.
        // In points at 2.625: inner 841×701, cover 411×797. Approx.: density assumed. The inner camera sits in the bezel.
        // OS: Android 17, the November 2026 Pixel update, build CP4A.261105.040.A1 (same build as the Pixel 8; droid-life.com).
        DeviceProfile(id: "pixel-fold", name: "Pixel Fold", family: .foldable, screenWidth: 841, screenHeight: 701, scale: 2.625,
                      cornerRadius: 24, safeArea: DeviceInsets(top: 28, bottom: 24), cutout: .punchHole, foldedWidth: 411, foldedHeight: 797,
                      os: "Android", osVersion: "17", make: "Google", model: "Pixel Fold",
                      userAgent: androidWebViewUserAgent(android: "17", model: "Pixel Fold", build: "CP4A.261105.040.A1"), openRTBDeviceType: 4),
    ]

    // MARK: - Dual-screen

    private static let dualScreens: [DeviceProfile] = [
        // Surface Duo (Microsoft dual-screen docs): each screen 1350×1800 px at 2.5 → 540×720; spanned viewport 1114×720,
        // i.e. a 34 px hinge between the screens. Screen corner radius and insets approx.
        // OS: its last update, Android 12L (API 32; rolled out from 24 Oct 2022, 9to5google.com/2022/10/24/surface-duo-
        // android-12l-update; OS and security updates ended 10 Sep 2023). 12L reports itself as "12" (Build.VERSION.RELEASE),
        // which is what the WebView User-Agent and `device.osv` carry.
        DeviceProfile(id: "surface-duo", name: "Surface Duo", family: .dualScreen, screenWidth: 540, screenHeight: 720, scale: 2.5,
                      cornerRadius: 6, safeArea: DeviceInsets(top: 24, bottom: 24), cutout: .none, hingeWidth: 34,
                      os: "Android", osVersion: "12", make: "Microsoft", model: "Surface Duo",
                      userAgent: androidWebViewUserAgent(android: "12", model: "Surface Duo", build: "2023.814.31"), openRTBDeviceType: 4),
    ]

    // MARK: - Tablets

    /// iPadOS 13+ browses desktop-class by default (`WKWebpagePreferences.preferredContentMode` `.recommended` resolves to
    /// desktop on iPad), so an in-app `WKWebView` sends the Macintosh UA. WebKit builds it in
    /// Source/WebCore/platform/ios/UserAgentIOS.mm (`standardUserAgentWithApplicationName`, desktop type) as
    /// `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)` followed by the desktop
    /// application name, which `WKWebViewConfiguration._applicationNameForDesktopUserAgent` leaves empty by default (the
    /// `Mobile/15E148` default of `applicationNameForUserAgent` applies to the mobile UA only). The Mac OS token is frozen
    /// at 10_15_7. `device.os` / `osv` still say iPadOS 27.2, as SDKs report them from UIDevice.
    private static let iPadUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    private static let tablets: [DeviceProfile] = [
        // HIG: 820×1180 pt @2x (2360×1640 px). 24 pt status bar, 20 pt home indicator; display corner radius 18 pt.
        DeviceProfile(id: "ipad-10", name: "iPad (10th gen)", family: .tablet, screenWidth: 820, screenHeight: 1180, scale: 2, cornerRadius: 18,
                      safeArea: DeviceInsets(top: 24, bottom: 20), os: "iPadOS", osVersion: iOSVersion, make: "Apple", model: "iPad13,18",
                      userAgent: iPadUserAgent, openRTBDeviceType: 5),
        // HIG: 834×1194 pt @2x (2388×1668 px), iPad Pro 11-inch (1st–4th gen). Same insets and corner radius as above.
        DeviceProfile(id: "ipad-pro-11", name: "iPad Pro 11\" (4th gen)", family: .tablet, screenWidth: 834, screenHeight: 1194, scale: 2,
                      cornerRadius: 18, safeArea: DeviceInsets(top: 24, bottom: 20), os: "iPadOS", osVersion: iOSVersion, make: "Apple",
                      model: "iPad14,3", userAgent: iPadUserAgent, openRTBDeviceType: 5),
        // Apple: iPad Pro 11-inch (M4, 2024; M5, 2025) 2420×1668 px @2x → 834×1210 pt. Same insets; corner radius approx.
        DeviceProfile(id: "ipad-pro-11-m5", name: "iPad Pro 11\" (M5)", family: .tablet, screenWidth: 834, screenHeight: 1210, scale: 2,
                      cornerRadius: 18, safeArea: DeviceInsets(top: 24, bottom: 20), os: "iPadOS", osVersion: iOSVersion, make: "Apple",
                      model: "iPad17,1", userAgent: iPadUserAgent, openRTBDeviceType: 5),
    ]

    // MARK: - Connected TV

    private static func tv(_ id: String, _ name: String, scale: Double, os: String, osVersion: String, make: String, model: String,
                           userAgent: String, deviceType: Int) -> DeviceProfile {
        DeviceProfile(id: id, name: name, family: .ctv, screenWidth: 1920, screenHeight: 1080, scale: scale, os: os, osVersion: osVersion,
                      make: make, model: model, userAgent: userAgent, openRTBDeviceType: deviceType, input: .remote, supportsClickThrough: false)
    }

    private static let connectedTVs: [DeviceProfile] = [
        // Apple TV 4K (3rd generation, 2022; AppleTV14,1). tvOS lays out 1920×1080 pt; the 4K model renders @2x.
        // OS: tvOS 27.2, build 24K122 (26 Oct 2026, with iOS 27.2; the 24K154 build is only for the 4th generation). The
        //   UA is AVPlayer's AppleCoreMedia one, which reports the real OS version (WebKit's frozen `18_6` does not apply).
        // Device type 7 (set-top box), not 3: AdCOM's 3 "Connected TV" is a TV set with the platform built in, 7 "Set Top
        //   Box" a device plugged into one, which an Apple TV is. Exchanges that send 3 for every CTV device are not wrong
        //   for their own taxonomy, so the simulator only reports it: no behaviour keys off it (see the header).
        tv("apple-tv-4k", "Apple TV 4K", scale: 2, os: "tvOS", osVersion: "27.2", make: "Apple", model: "AppleTV14,1",
           userAgent: "AppleCoreMedia/1.0.0.24K122 (Apple TV; U; CPU OS 27_2 like Mac OS X; en_us)", deviceType: 7),
        // A 4K TV set with Google TV built in → connected TV (3). Android TV 14: Sony moved its Realtek-based BRAVIA sets
        // to it from August 2025, and Android TV 16 had not reached TV sets by November 2026 (Google skipped 15).
        // ExoPlayer-based apps send the Dalvik UA. Model name and build approx.
        tv("google-tv", "Google TV (4K TV)", scale: 2, os: "Android", osVersion: "14", make: "Sony", model: "BRAVIA 4K VH2",
           userAgent: "Dalvik/2.1.0 (Linux; U; Android 14; BRAVIA 4K VH2 Build/UTT3.250605.001.S2)", deviceType: 3),
        // Fire TV Stick 4K Max (2nd generation, 2023; model code AFTKRT, "karat") → set-top box (7). Fire OS 8.1.8.5
        // (build RS8185/3898, 28 Oct 2026, ftvdb.com), which is Android 11 (API 30) underneath: the Dalvik UA says Android 11.
        tv("fire-tv-stick-4k", "Fire TV Stick 4K Max (2nd gen)", scale: 2, os: "Fire OS", osVersion: "8.1.8.5", make: "Amazon", model: "AFTKRT",
           userAgent: "Dalvik/2.1.0 (Linux; U; Android 11; AFTKRT Build/RS8185.3898N)", deviceType: 7),
        // Roku Express: a 1080p player → set-top box (7). Roku OS 15.3 (13 Aug 2026), the release on most devices: 16.0
        // started a staged rollout on 19 Oct 2026. roUrlTransfer's default `Roku/DVP-<os> (<build>)` UA. Model code and
        // build approx.
        tv("roku-express", "Roku Express (1080p)", scale: 1, os: "Roku OS", osVersion: "15.3", make: "Roku", model: "3960X",
           userAgent: "Roku/DVP-15.3 (15.3.0.6075-46)", deviceType: 7),
    ]
}
