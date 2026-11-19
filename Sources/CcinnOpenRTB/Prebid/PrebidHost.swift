import CcinnOpenRTBKit
import Foundation
import WebKit

/// The web view that runs a Prebid page: the page is the simulated response to its own URL (nothing is fetched for it),
/// the shim routes its scripts and network through the app, a content rule list blocks every other load, a navigation
/// guard keeps the frame on the page, and the page's events come back as (type, JSON) pairs. Non-persistent website
/// data; the simulated browser's User-Agent.
@MainActor
final class PrebidHost {
    let webView: WKWebView
    let bridge: PrebidNetworkBridge
    private let library: PrebidLibrary
    private let events = EventRelay()
    private let guardian = NavigationGuard()

    enum Failure: Error, LocalizedError {
        case contentRules(String)

        var errorDescription: String? {
            switch self {
            case let .contentRules(reason): "The page’s content rules did not compile, so it is not loaded: \(reason)"
            }
        }
    }

    /// The page's events: `ready`, Prebid's (`bidResponse`, `noBid`, `auctionEnd` …), `bidsBack`, `sync`, `log`,
    /// `scriptError`.
    var onEvent: ((_ type: String, _ payload: String) -> Void)? {
        get { events.onEvent }
        set { events.onEvent = newValue }
    }

    init(library: PrebidLibrary, bridge: PrebidNetworkBridge, userAgent: String) {
        self.library = library
        self.bridge = bridge
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: PrebidShim.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: PrebidShim.networkHandler)
        content.add(events, contentWorld: .page, name: PrebidPage.eventsHandler)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 760), configuration: configuration)
        webView.customUserAgent = userAgent
        webView.navigationDelegate = guardian
    }

    /// Loads `html` as the page at `url`, running Prebid.js `version`. The content rules are in place first; if they
    /// cannot be, nothing loads.
    func load(_ html: String, at url: URL, version: String, userAgent: String) async throws {
        let rules: WKContentRuleList
        do {
            rules = try await CreativeContentRules.prebidPage()
        } catch {
            throw Failure.contentRules(error.localizedDescription)
        }
        let content = webView.configuration.userContentController
        content.removeAllContentRuleLists()
        content.add(rules)
        let library = library
        bridge.page = PrebidNetworkBridge.Page(url: url, scripts: { try await library.script(at: $0, version: version) })
        guardian.page = url
        webView.customUserAgent = userAgent
        webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
    }

    func stop() {
        bridge.page = nil
        guardian.page = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    func tearDown() {
        stop()
        let content = webView.configuration.userContentController
        content.removeAllScriptMessageHandlers()
        content.removeAllUserScripts()
    }

    /// Kept apart from the host: the user content controller retains its handlers.
    private final class EventRelay: NSObject, WKScriptMessageHandler {
        var onEvent: ((String, String) -> Void)?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            onEvent?(type, body["payload"] as? String ?? "null")
        }
    }

    /// The main frame stays on the page (an adapter or a creative cannot take it elsewhere); frames get only local
    /// documents (`about:`, `blob:`, `data:`), their network loads being the shim's business.
    @MainActor
    private final class NavigationGuard: NSObject, WKNavigationDelegate {
        var page: URL?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.targetFrame?.isMainFrame != false {
                return url == page || (page == nil && url.absoluteString == "about:blank") ? .allow : .cancel
            }
            return ["about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel
        }
    }
}
