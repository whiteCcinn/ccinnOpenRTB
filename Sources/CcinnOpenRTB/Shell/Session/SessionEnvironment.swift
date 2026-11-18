import AppKit
import CcinnOpenRTBKit
import Foundation
import RTBKit

/// Monotonic seconds for the viewability timers; injectable so tests move time by hand.
protocol SessionClock: Sendable {
    func now() -> Double
}

struct SystemSessionClock: SessionClock {
    func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// Opens click-throughs in the default browser (Real mode with the setting on); injectable for tests. Returns whether the
/// URL was handed to a browser.
@MainActor
protocol BrowserOpening: AnyObject {
    @discardableResult
    func open(_ url: URL) -> Bool
}

/// The landing page is a web page: it opens in the default web browser — the app that opens https URLs, resolved
/// explicitly — never in whichever app claims the URL (a universal link, an app registered for the advertiser's domain),
/// which the system's generic open would pick. No browser: nothing opens. Only http(s) URLs.
@MainActor
final class WorkspaceBrowser: BrowserOpening {
    typealias BrowserResolver = @MainActor () -> URL?
    typealias Opener = @MainActor (_ url: URL, _ application: URL) -> Void

    private let defaultBrowser: BrowserResolver
    private let openWith: Opener

    init(defaultBrowser: @escaping BrowserResolver = WorkspaceBrowser.systemDefaultBrowser,
         openWith: @escaping Opener = WorkspaceBrowser.systemOpen) {
        self.defaultBrowser = defaultBrowser
        self.openWith = openWith
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let browser = defaultBrowser() else {
            return false
        }
        openWith(url, browser)
        return true
    }

    /// The app that opens a plain https URL (a neutral one no app claims): the user's default web browser.
    static func systemDefaultBrowser() -> URL? {
        guard let probe = URL(string: "https://example.com/") else { return nil }
        return browser(NSWorkspace.shared.urlForApplication(toOpen: probe), isNot: Bundle.main.bundleURL)
    }

    /// `candidate`, unless it is the simulator itself (which would load the landing page inside the app).
    static func browser(_ candidate: URL?, isNot app: URL) -> URL? {
        guard let candidate else { return nil }
        return candidate.standardizedFileURL.resolvingSymlinksInPath() == app.standardizedFileURL.resolvingSymlinksInPath() ? nil : candidate
    }

    static func systemOpen(_ url: URL, _ application: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration, completionHandler: nil)
    }
}
