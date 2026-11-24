import Foundation

/// The OS family that decides how a device opens a URL.
public enum DevicePlatform: String, Sendable, Hashable {
    case apple, android, other
}

extension DeviceProfile {
    /// iOS and iPadOS open URLs one way, Android another; CTV platforms have no click-through.
    public var platform: DevicePlatform {
        switch os.lowercased() {
        case "ios", "ipados": .apple
        case "android": .android
        default: .other
        }
    }
}

/// A query parameter of a link, decoded, in order.
public struct LinkParameter: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A third-party app a deep link opened.
public struct ThirdPartyApp: Sendable, Hashable {
    /// Guessed from the scheme or the Android package ("Lazada" for `lazada:` or `com.lazada.android`).
    public var name: String
    /// What names the app: its URL scheme (`lazada:`) or Android package (`com.lazada.android`).
    public var identifier: String
    /// The URL the app receives.
    public var link: String
    /// The link's host and path, which the app routes on: `product/123`.
    public var route: String
    public var parameters: [LinkParameter]

    public init(name: String, identifier: String, link: String, route: String, parameters: [LinkParameter]) {
        self.name = name
        self.identifier = identifier
        self.link = link
        self.route = route
        self.parameters = parameters
    }
}

/// A store's product page.
public struct StorePage: Sendable, Hashable {
    public enum Store: String, Sendable, Hashable {
        case appStore = "App Store"
        case googlePlay = "Google Play"
    }

    public var store: Store
    /// `id1234567890` (App Store) or the package (Google Play); empty when the link names none.
    public var appID: String
    public var url: String
    public var parameters: [LinkParameter]

    public init(store: Store, appID: String, url: String, parameters: [LinkParameter]) {
        self.store = store
        self.appID = appID
        self.url = url
        self.parameters = parameters
    }
}

/// A web page in the in-app browser (SFSafariViewController, a Chrome Custom Tab).
public struct WebPage: Sendable, Hashable {
    public var url: String
    public var host: String
    public var parameters: [LinkParameter]

    public init(url: String, host: String, parameters: [LinkParameter]) {
        self.url = url
        self.host = host
        self.parameters = parameters
    }
}

/// A system app a `tel:`, `sms:` or `mailto:` link opens.
public enum SystemApp: String, Sendable, Hashable {
    case phone = "Phone"
    case messages = "Messages"
    case mail = "Mail"
}

/// What opens on the device.
public enum ClickThroughScreen: Sendable, Hashable {
    case browser(WebPage)
    case app(ThirdPartyApp)
    case store(StorePage)
    /// `target`: the number or address.
    case system(SystemApp, target: String)
}

/// What a device does with a click-through: the screen that opens (none when nothing can open the link) and the
/// decision, step by step.
public struct ClickThroughResolution: Sendable, Hashable {
    public var screen: ClickThroughScreen?
    public var steps: [String]
    /// The bid's fallback was used because the link itself could not be opened.
    public var usedFallback: Bool

    /// One line for the click's Network entry.
    public var summary: String { steps.joined(separator: " → ") }
}

/// Decides what a device does with a click-through URL, as an SDK and the OS would (pure).
///
/// - `http(s)`: the in-app browser — except App Store links on iOS and Google Play links on Android, which open the store.
///   Universal Links and App Links open as web pages: the simulator cannot know which domains an app claims.
/// - `itms-apps:` / `itms-appss:` / `itms:` open the App Store on iOS, `market:` Google Play on Android; nothing opens them
///   on the other platform.
/// - `intent:` (Android): the app when installed, else `S.browser_fallback_url`, else the package's Play page.
/// - `tel:`, `sms:`, `mailto:`: Phone, Messages, Mail.
/// - Any other scheme is a deep link: it opens its app when `appsInstalled`.
/// When the link cannot be opened, the bid's `fallback` (Native `link.fallback`, AdCOM `urlfb`) is tried once.
public enum ClickThroughResolver {
    public static func resolve(_ url: String, fallback: String? = nil, platform: DevicePlatform, appsInstalled: Bool) -> ClickThroughResolution {
        let first = attempt(url, platform: platform, appsInstalled: appsInstalled)
        if let screen = first.screen { return ClickThroughResolution(screen: screen, steps: first.steps, usedFallback: false) }
        var steps = first.steps
        guard let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty else {
            steps.append("No fallback in the bid: nothing opens")
            return ClickThroughResolution(screen: nil, steps: steps, usedFallback: false)
        }
        let second = attempt(fallback, platform: platform, appsInstalled: appsInstalled)
        steps.append("Fallback \(fallback): " + second.steps.joined(separator: "; "))
        if second.screen == nil { steps.append("Nothing opens") }
        return ClickThroughResolution(screen: second.screen, steps: steps, usedFallback: second.screen != nil)
    }

    private struct Attempt {
        var screen: ClickThroughScreen?
        var steps: [String]
    }

    private static func attempt(_ url: String, platform: DevicePlatform, appsInstalled: Bool) -> Attempt {
        let link = Link(url)
        guard platform != .other else { return Attempt(steps: ["This device does not open links"]) }
        switch link.scheme {
        case "http", "https":
            return web(link, platform: platform)
        case "itms-apps", "itms-appss", "itms":
            guard platform == .apple else { return Attempt(steps: ["No app on Android opens \(link.scheme): links"]) }
            let id = appStoreID(in: link.path) ?? ""
            return Attempt(screen: .store(StorePage(store: .appStore, appID: id, url: link.text, parameters: link.parameters)),
                           steps: ["\(link.scheme): opens the App Store" + (id.isEmpty ? "" : " (\(id))")])
        case "market":
            guard platform == .android else { return Attempt(steps: ["No app on iOS opens market: links"]) }
            let id = link.parameter("id") ?? ""
            return Attempt(screen: .store(StorePage(store: .googlePlay, appID: id, url: link.text, parameters: link.parameters)),
                           steps: ["market: opens Google Play" + (id.isEmpty ? "" : " (\(id))")])
        case "intent":
            return intent(link, platform: platform, appsInstalled: appsInstalled)
        case "tel", "sms", "mailto":
            let app: SystemApp = link.scheme == "tel" ? .phone : (link.scheme == "sms" ? .messages : .mail)
            let target = link.opaqueTarget
            return Attempt(screen: .system(app, target: target), steps: ["\(link.scheme): opens \(app.rawValue)" + (target.isEmpty ? "" : " (\(target))")])
        case "":
            return Attempt(steps: ["\(url.isEmpty ? "An empty link" : "\(url)") is not a URL: nothing opens it"])
        default:
            let app = ThirdPartyApp(name: appName(scheme: link.scheme), identifier: link.scheme + ":", link: link.text, route: link.route,
                                    parameters: link.parameters)
            guard appsInstalled else { return Attempt(steps: ["Deep link: no installed app opens \(link.scheme): links"]) }
            return Attempt(screen: .app(app), steps: ["Deep link: \(app.name) (\(app.identifier)) is installed and opens it"])
        }
    }

    private static func web(_ link: Link, platform: DevicePlatform) -> Attempt {
        let host = link.host.lowercased()
        if host == "apps.apple.com" || host == "itunes.apple.com", let id = appStoreID(in: link.path) {
            guard platform == .apple else {
                return Attempt(screen: .browser(page(link)), steps: ["An App Store link on Android: opens as a web page in the in-app browser"])
            }
            return Attempt(screen: .store(StorePage(store: .appStore, appID: id, url: link.text, parameters: link.parameters)),
                           steps: ["An App Store link: opens the App Store (\(id))"])
        }
        if host == "play.google.com", link.path.hasPrefix("/store/apps/details"), let id = link.parameter("id"), !id.isEmpty {
            guard platform == .android else {
                return Attempt(screen: .browser(page(link)), steps: ["A Google Play link on iOS: opens as a web page in the in-app browser"])
            }
            return Attempt(screen: .store(StorePage(store: .googlePlay, appID: id, url: link.text, parameters: link.parameters)),
                           steps: ["A Google Play link: opens Google Play (\(id))"])
        }
        return Attempt(screen: .browser(page(link)), steps: ["Opens in the in-app browser"])
    }

    private static func page(_ link: Link) -> WebPage {
        WebPage(url: link.text, host: link.host, parameters: link.parameters)
    }

    /// Chrome's intent syntax: `intent://HOST/PATH#Intent;scheme=S;package=P;S.browser_fallback_url=U;end`.
    private static func intent(_ link: Link, platform: DevicePlatform, appsInstalled: Bool) -> Attempt {
        guard platform == .android else { return Attempt(steps: ["intent: links are Android's: nothing on iOS opens them"]) }
        let extras = link.intentExtras
        let package = extras["package"].flatMap { $0.isEmpty ? nil : $0 }
        let scheme = extras["scheme"].flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let target = Link((scheme ?? "intent") + ":" + link.beforeFragment.dropFirst("intent:".count))
        let name = package.map { appName(package: $0) } ?? scheme.map { appName(scheme: $0) }
        if appsInstalled, let name {
            let app = ThirdPartyApp(name: name, identifier: package ?? (target.scheme + ":"), link: target.text, route: target.route,
                                    parameters: target.parameters)
            return Attempt(screen: .app(app), steps: ["intent: \(app.identifier) is installed and opens \(target.text)"])
        }
        let missing = name == nil ? "intent: names no app (no package or scheme)" : "intent: " + (package ?? (target.scheme + ":")) + " is not installed"
        if let fallback = extras["S.browser_fallback_url"], !fallback.isEmpty {
            let page = Link(fallback)
            if page.scheme == "http" || page.scheme == "https" {
                return Attempt(screen: .browser(self.page(page)), steps: [missing + ": its browser fallback opens in the in-app browser"])
            }
        }
        if let package {
            let store = StorePage(store: .googlePlay, appID: package, url: "market://details?id=" + package, parameters: [LinkParameter("id", package)])
            return Attempt(screen: .store(store), steps: [missing + ": Google Play opens its page"])
        }
        return Attempt(steps: [missing + ", and it has no browser fallback"])
    }

    /// `id1234567890` in an App Store path.
    static func appStoreID(in path: String) -> String? {
        guard let range = path.range(of: #"id[0-9]+"#, options: .regularExpression) else { return nil }
        return String(path[range])
    }

    /// "Lazada" from `lazada`, "FB" from `fb`.
    public static func appName(scheme: String) -> String {
        let name = scheme.lowercased()
        guard let first = name.first else { return "App" }
        return name.count <= 3 ? name.uppercased() : first.uppercased() + name.dropFirst()
    }

    private static let genericPackageParts: Set<String> = [
        "com", "net", "org", "io", "co", "app", "apps", "android", "mobile", "client", "global", "lite", "main", "prod", "release",
        "my", "id", "sg", "th", "vn", "ph", "tw", "cn", "jp", "kr", "us", "uk", "in", "br", "mx",
    ]

    /// "Shopee" from `com.shopee.my`, "Lazada" from `com.lazada.android`: the last part that is not a TLD, country or
    /// generic word.
    public static func appName(package: String) -> String {
        let parts = package.split(separator: ".").map(String.init)
        let meaningful = parts.reversed().first { !genericPackageParts.contains($0.lowercased()) && $0.count > 1 } ?? parts.last ?? package
        return appName(scheme: meaningful)
    }
}

/// A URL read leniently (pure): click-throughs may hold unexpanded macros (`${AUCTION_PRICE}`, `[ERRORCODE]`) or spaces
/// that `URLComponents` rejects.
struct Link {
    /// The trimmed text.
    let text: String
    /// Lower-cased; empty when there is none.
    let scheme: String
    let host: String
    let path: String
    let query: String
    /// Everything before `#`.
    let beforeFragment: String
    let fragment: String

    init(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = text
        var rest = Substring(text)
        if let colon = text.firstIndex(of: ":"), colon != text.startIndex,
           text[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }),
           text.first?.isLetter == true {
            scheme = text[..<colon].lowercased()
            rest = text[text.index(after: colon)...]
        } else {
            scheme = ""
        }
        let hash = rest.firstIndex(of: "#")
        fragment = hash.map { String(rest[rest.index(after: $0)...]) } ?? ""
        let body = hash.map { rest[..<$0] } ?? rest
        beforeFragment = hash.map { String(text[..<$0]) } ?? text
        let question = body.firstIndex(of: "?")
        query = question.map { String(body[body.index(after: $0)...]) } ?? ""
        var hierarchy = question.map { body[..<$0] } ?? body
        if hierarchy.hasPrefix("//") {
            hierarchy = hierarchy.dropFirst(2)
            let slash = hierarchy.firstIndex(of: "/") ?? hierarchy.endIndex
            var authority = hierarchy[..<slash]
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            if let port = authority.lastIndex(of: ":"), authority[authority.index(after: port)...].allSatisfy(\.isNumber) {
                authority = authority[..<port]
            }
            host = String(authority)
            path = String(hierarchy[slash...])
        } else {
            host = ""
            path = String(hierarchy)
        }
    }

    /// Host and path without the leading slash: what an app routes on (`lazada://product/123` → `product/123`).
    var route: String {
        let joined = host.isEmpty ? path : host + path
        return joined.hasPrefix("/") ? String(joined.dropFirst()) : joined
    }

    /// The target of an opaque link: the number of `tel:`, the address of `mailto:`.
    var opaqueTarget: String {
        let target = route
        return target.removingPercentEncoding ?? target
    }

    var parameters: [LinkParameter] {
        query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            return LinkParameter(name.removingPercentEncoding ?? name, value.removingPercentEncoding ?? value)
        }
    }

    func parameter(_ name: String) -> String? {
        parameters.first { $0.name == name }?.value
    }

    /// `Intent;scheme=S;package=P;S.browser_fallback_url=U;end` → its values, percent-decoded.
    var intentExtras: [String: String] {
        guard fragment.hasPrefix("Intent;") else { return [:] }
        var extras: [String: String] = [:]
        for item in fragment.dropFirst("Intent;".count).split(separator: ";") where item != "end" {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            extras[String(parts[0])] = value.removingPercentEncoding ?? value
        }
        return extras
    }
}
