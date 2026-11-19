import CcinnOpenRTBKit
import Foundation
import WebKit

/// The web view that runs a Prebid page: the page is the simulated response to its own URL (nothing is fetched for it),
/// the shim routes its scripts and network through the app, a Content-Security-Policy and a content rule list block every
/// other load, a navigation guard keeps the frame on the page, and the page's events come back as (type, JSON) pairs —
/// only from the run being loaded. Non-persistent website data, emptied before every run; the simulated browser's
/// User-Agent.
@MainActor
final class PrebidHost {
    let webView: WKWebView
    let bridge: PrebidNetworkBridge
    private let library: PrebidLibrary
    private let events = EventRelay()
    private let guardian = NavigationGuard()
    /// The run the page belongs to; `nil` when none runs. Events and requests of any other run are dropped.
    private(set) var run: String?

    /// An event at most this large is delivered (a bigger one is dropped, and the drop is reported).
    static let maxEventBytes = 8 * 1024 * 1024

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
    var onEvent: ((_ type: String, _ payload: String) -> Void)?

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
        events.deliver = { [weak self] type, payload, run in
            guard let self, let run, run == self.run else { return }
            guard payload.utf8.count <= Self.maxEventBytes else {
                self.onEvent?("log", #"{"level":"warn","message":"A page event larger than 8 MiB was dropped."}"#)
                return
            }
            self.onEvent?(type, payload)
        }
    }

    /// Loads `html` (built for `run`) as the page at `url`, running Prebid.js `version`. The content rules are in place
    /// and the website data is emptied first; if the rules cannot be, nothing loads. A `stop()` or another `load` while
    /// this one waits wins: this one then loads nothing.
    func load(_ html: String, at url: URL, version: String, userAgent: String, run: String, clientHints: [String: String] = [:]) async throws {
        stop()
        self.run = run
        let rules: WKContentRuleList
        do {
            rules = try await CreativeContentRules.prebidPage()
        } catch {
            if self.run == run { self.run = nil }
            throw Failure.contentRules(error.localizedDescription)
        }
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        guard self.run == run else { return }
        let content = webView.configuration.userContentController
        content.removeAllContentRuleLists()
        content.add(rules)
        let library = library
        bridge.page = PrebidNetworkBridge.Page(url: url, run: run, clientHints: clientHints,
                                               scripts: { try await library.script(at: $0, version: version) })
        guardian.allowNextMainFrameLoad()
        webView.customUserAgent = userAgent
        webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
    }

    /// Ends the run: its events and requests are dropped from now on, and the page goes.
    func stop() {
        run = nil
        bridge.page = nil
        guardian.stop()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    func tearDown() {
        stop()
        onEvent = nil
        let content = webView.configuration.userContentController
        content.removeAllScriptMessageHandlers()
        content.removeAllUserScripts()
    }

    /// Kept apart from the host: the user content controller retains its handlers.
    private final class EventRelay: NSObject, WKScriptMessageHandler {
        var deliver: ((String, String, String?) -> Void)?

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            deliver?(type, body["payload"] as? String ?? "null", body["run"] as? String)
        }
    }

    /// The main frame loads one http(s) document per run — the page itself, whatever URL WebKit made of it
    /// (`https://news.example` → `…/`) — and then stays: an adapter or a creative cannot take it elsewhere. `about:blank`
    /// (loads nothing; `stop()` uses it) is always allowed. Frames get only local documents (`about:`, `blob:`, `data:`);
    /// their network loads are the shim's business.
    @MainActor
    private final class NavigationGuard: NSObject, WKNavigationDelegate {
        private var allowsPage = false

        func allowNextMainFrameLoad() { allowsPage = true }
        func stop() { allowsPage = false }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            let scheme = url.scheme?.lowercased() ?? ""
            guard navigationAction.targetFrame?.isMainFrame != false else { return ["about", "blob", "data"].contains(scheme) ? .allow : .cancel }
            if url.absoluteString == "about:blank" { return .allow }
            guard allowsPage, scheme == "https" || scheme == "http" else { return .cancel }
            allowsPage = false
            return .allow
        }
    }
}
