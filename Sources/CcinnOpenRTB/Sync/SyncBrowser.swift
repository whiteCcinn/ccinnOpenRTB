import RTBKit

/// The browser a cookie sync runs in: it decides the third-party cookie policy and the User-Agent the partners see.
/// Web cookie mapping happens in a browser; an app's web view and a TV app are listed too, because their cookie rules are
/// what an in-app sync meets.
enum SyncBrowser: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Safari on iPhone and iPad (WebKit: third-party cookies blocked).
    case safari
    /// An iPhone or iPad app's web view (WKWebView: third-party cookies blocked).
    case iosApp
    /// Chrome on Android (SameSite=None; Secure required, Lax by default, CHIPS).
    case chrome
    /// An Android app's WebView: `acceptThirdPartyCookies` is off by default (API 21 and later).
    case androidApp
    /// Firefox (Total Cookie Protection: partitioned per top-level site).
    case firefox
    /// A TV app: no browser cookie jar shared with the web.
    case tvApp

    var id: String { rawValue }

    var policy: CookiePolicy {
        switch self {
        case .safari, .iosApp, .androidApp, .tvApp: .blockThirdParty
        case .chrome: .allowThirdParty
        case .firefox: .partitioned
        }
    }

    var title: String {
        switch self {
        case .safari: "Safari"
        case .iosApp: "iOS app web view"
        case .chrome: "Chrome on Android"
        case .androidApp: "Android app WebView"
        case .firefox: "Firefox"
        case .tvApp: "TV app"
        }
    }

    var detail: String {
        switch self {
        case .safari: "WebKit blocks third-party cookies: nothing is stored or sent cross-site"
        case .iosApp: "WKWebView blocks third-party cookies, as Safari does"
        case .chrome: "Third-party cookies need SameSite=None; Secure; a missing SameSite is Lax; Partitioned (CHIPS) is kept per site"
        case .androidApp: "Android WebView: third-party cookies are off unless the app turns on acceptThirdPartyCookies"
        case .firefox: "Total Cookie Protection: third-party cookies are kept per top-level site"
        case .tvApp: "A TV app has no browser cookie jar shared with the web"
        }
    }

    /// The device's browser: Safari on Apple phones and tablets, Chrome on Android, none on a TV.
    static func `default`(for device: DeviceProfile) -> SyncBrowser {
        if device.family == .ctv || device.os == "tvOS" { return .tvApp }
        if device.os == "iOS" || device.os == "iPadOS" { return .safari }
        return .chrome
    }

    /// The User-Agent this browser sends on `device`. Apps send the device's web view User-Agent; Safari adds its
    /// `Version/… Safari/…` tokens; Chrome and Firefox send their reduced Android forms.
    func userAgent(for device: DeviceProfile) -> String {
        switch self {
        case .iosApp, .androidApp, .tvApp:
            return device.userAgent
        case .safari:
            if device.userAgent.contains("Macintosh") { return device.userAgent + " Version/\(device.osVersion) Safari/605.1.15" }
            if let range = device.userAgent.range(of: " Mobile/") {
                var agent = device.userAgent
                agent.insert(contentsOf: " Version/\(device.osVersion)", at: range.lowerBound)
                return agent + " Safari/604.1"
            }
            return device.userAgent + " Version/\(device.osVersion) Safari/604.1"
        case .chrome:
            return "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chromeMajor).0.0.0 Mobile Safari/537.36"
        case .firefox:
            return "Mozilla/5.0 (Android \(Self.androidVersion); Mobile; rv:\(Self.firefoxMajor).0) Gecko/\(Self.firefoxMajor).0 Firefox/\(Self.firefoxMajor).0"
        }
    }

    /// November 2026 releases (the catalog's Android System WebView is Chrome 157).
    static let chromeMajor = 157
    static let firefoxMajor = 159
    static let androidVersion = 17
}
