import Foundation
import RTBKit

/// What a click-through opened on the device, covering the publisher app until Back: another app, a store, the in-app
/// browser or a system app (`ClickThroughResolver`).
struct DeviceForeground: Equatable, Identifiable {
    let id = UUID()
    var screen: ClickThroughScreen
    var platform: DevicePlatform
    /// The link could not be opened; the bid's fallback was.
    var usedFallback: Bool
    /// The page was also opened in the Mac's default browser (Real mode, "Open click-throughs in browser").
    var openedOnMac: Bool

    /// Another app took the screen: a deep link's app, a system app, a store app (`itms-apps:`, Google Play) — not the
    /// in-app browser, nor the App Store page an iOS SDK presents inside the publisher app for an `https` App Store link.
    var jumpedToAnotherApp: Bool {
        switch screen {
        case .app, .system: true
        case let .store(page): platform == .android || !page.url.lowercased().hasPrefix("http")
        case .browser: false
        }
    }

    /// iOS shows "◀ App" in the status bar after a jump to another app; Android has its Back.
    var showsBackBreadcrumb: Bool { platform == .apple && jumpedToAnotherApp }
}

/// A click-through that opened nothing: the device says why until it is dismissed or something else happens.
struct ClickThroughNotice: Equatable, Identifiable {
    let id = UUID()
    var text: String
}

extension ClickThroughResolution {
    /// The page the device shows in a browser or store sheet, when it is a web page the Mac could open too.
    var webPageURL: String? {
        let url: String
        switch screen {
        case let .browser(page): url = page.url
        case let .store(page): url = page.url
        case .app, .system, nil: return nil
        }
        let lowered = url.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://") ? url : nil
    }

    /// The decision as sentences, for the device's notice.
    var sentences: String {
        steps.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }
}
