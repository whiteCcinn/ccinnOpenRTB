import CcinnOpenRTBKit
import Foundation
import WebKit

/// The web view that runs a Prebid page: the `ccinn-prebid` scheme serves the page and Prebid.js, the shim routes its
/// network through the window's monitor, a content rule list blocks everything else, and the page's events come back as
/// (type, JSON) pairs. Non-persistent website data; the simulated browser's User-Agent.
@MainActor
final class PrebidHost {
    let webView: WKWebView
    let schemeHandler: PrebidSchemeHandler
    let bridge: PrebidNetworkBridge
    private let events = EventRelay()

    /// The page's events: `ready`, Prebid's (`bidResponse`, `noBid`, `auctionEnd` …), `bidsBack`, `sync`, `log`.
    var onEvent: ((_ type: String, _ payload: String) -> Void)? {
        get { events.onEvent }
        set { events.onEvent = newValue }
    }

    init(library: PrebidLibrary, bridge: PrebidNetworkBridge, userAgent: String) {
        schemeHandler = PrebidSchemeHandler(library: library)
        self.bridge = bridge
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: PrebidPage.scheme)
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: PrebidShim.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: PrebidShim.networkHandler)
        content.add(events, contentWorld: .page, name: PrebidPage.eventsHandler)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 240), configuration: configuration)
        webView.customUserAgent = userAgent
    }

    /// Loads `html` as the page at `url` (the content rules are in place first).
    func load(_ html: String, at url: URL) async {
        if let rules = try? await CreativeContentRules.prebidPage() {
            webView.configuration.userContentController.removeAllContentRuleLists()
            webView.configuration.userContentController.add(rules)
        }
        schemeHandler.page = html
        webView.load(URLRequest(url: url))
    }

    func stop() {
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
}
