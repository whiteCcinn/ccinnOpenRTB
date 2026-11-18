import Foundation

/// What WebKit asks about one navigation of the creative's web view (extracted from `WKNavigationAction`).
struct NavigationFacts: Equatable, Sendable {
    var url: String
    var isMainFrame: Bool
    /// `target=_blank` / `window.open` (no target frame).
    var targetsNewWindow: Bool
    /// The navigation of the document the controller is loading (its base URL, before that navigation was seen).
    var isInitialDocument: Bool
    /// The document's URL now (`WKWebView.url`), to recognise same-document fragment navigations.
    var currentURL: String?
}

enum NavigationDecision: Equatable, Sendable {
    /// Let WebKit load it (the creative document, or a subframe — the content rules govern its network).
    case allow
    /// Cancel; a user click-through: report the click and navigate.
    case click(url: String)
    /// Cancel; the creative tried to leave without a user gesture (auto-redirect): record it, no click.
    case autoRedirect(url: String)
    /// Cancel silently (not a navigable URL).
    case ignore
}

/// The creative must never leave its slot: only the document itself and its subframes load. Anything that would replace
/// the ad or open a window becomes a click-through when the user touched the ad within `gestureWindow` seconds (as an
/// SDK treats it), otherwise an auto-redirect, which SDKs block and the simulator records as such (pure).
enum NavigationClassifier {
    static let gestureWindow: TimeInterval = 1

    static func decide(_ facts: NavigationFacts, lastGesture: Date?, now: Date) -> NavigationDecision {
        if facts.isInitialDocument, facts.isMainFrame {
            return .allow
        }
        if !facts.isMainFrame, !facts.targetsNewWindow {
            return .allow
        }
        if facts.isMainFrame, !facts.targetsNewWindow, isFragmentNavigation(to: facts.url, from: facts.currentURL) {
            return .allow
        }
        guard isNavigable(facts.url) else { return .ignore }
        return hasRecentGesture(lastGesture, now: now) ? .click(url: facts.url) : .autoRedirect(url: facts.url)
    }

    /// `href="#…"` / `location.hash`: the same document scrolls, nothing loads. A URL without a fragment is a reload.
    static func isFragmentNavigation(to url: String, from current: String?) -> Bool {
        guard let current, let hash = url.firstIndex(of: "#") else { return false }
        let document = current.firstIndex(of: "#").map { current[..<$0] } ?? current[...]
        return url[..<hash] == document
    }

    static func hasRecentGesture(_ lastGesture: Date?, now: Date) -> Bool {
        guard let lastGesture else { return false }
        let age = now.timeIntervalSince(lastGesture)
        return age >= 0 && age <= gestureWindow
    }

    /// A destination a device could open: a web page, an app store or deep link — not `about:` / `javascript:` / `data:`.
    static func isNavigable(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":"), colon != trimmed.startIndex else { return false }
        let scheme = trimmed[..<colon].lowercased()
        guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else { return false }
        return !["about", "javascript", "data", "blob", "file"].contains(scheme)
    }
}
