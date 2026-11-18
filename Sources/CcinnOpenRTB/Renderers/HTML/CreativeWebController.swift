import AppKit
import CcinnOpenRTBKit
import Foundation
import WebKit

/// Owns one creative web view: the sandbox, the injected scripts, the bridge and navigation interception. Used for HTML ads
/// (with MRAID), HTML / iframe companions and script trackers; the owner maps its events to lifecycle events.
///
/// - Non-persistent data store, device User-Agent, no back/forward gestures, no magnification, inspectable.
/// - Simulated mode (`Content.blocksNetwork`): a content rule list blocks every http(s)/ws(s) load before the document is
///   loaded; if the rules cannot be compiled the creative is not loaded at all (fails closed).
/// - Nothing navigates the web view after the document: clicks are reported (`.click`), gesture-less attempts are
///   recorded as auto-redirects, `window.open` never opens a window.
/// - Main-actor only; `teardown()` removes the script handlers (they retain their target weakly anyway) and finishes the
///   creative loads still open.
@MainActor
final class CreativeWebController: NSObject {
    nonisolated static let baseURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "ccinn-openrtb.invalid"
        components.path = "/"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    /// Script-tracker pages (Real mode only): http, so an http tracker is not blocked as mixed content. A creative keeps
    /// the https base: its http scripts are blocked as an app's ATS / cleartext policy would block them.
    nonisolated static let trackerBaseURL: URL = {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "ccinn-openrtb.invalid"
        components.path = "/"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    struct Content: Equatable {
        /// The full document (see `HTMLDocumentBuilder`).
        var document: String
        /// The MRAID container to inject (`nil`: no MRAID, e.g. companions and script trackers).
        var mraid: MRAIDEnvironment?
        var blocksNetwork: Bool
        var disableScroll: Bool
        /// Network parent of the creative's requests (the markup's entry, when it was fetched).
        var networkParentID: UUID?
        /// Source path for navigations: `bid 0.0 › adm`.
        var source: String
        /// The document's URL (`loadHTMLString` base). The sandbox exempts only `CreativeWebController.baseURL`.
        var baseURL: URL = CreativeWebController.baseURL
    }

    enum Event: Equatable {
        /// The document finished loading (once per load).
        case loaded
        case failed(String)
        /// A user click-through (`trigger`: `navigation`, `target=_blank`, `window.open`).
        case click(url: String, trigger: String)
        case mraidOpen(url: String)
        case mraidState(String, customClose: Bool, size: MRAIDSize?)
        case mraidCommand(MRAIDCommand)
    }

    var onEvent: ((Event) -> Void)?
    let webView: WKWebView
    private weak var host: (any AdRenderingHost)?
    private let messageProxy = ScriptMessageProxy()
    private var content: Content?
    private var ledger = CreativeRequestLedger()
    private var lastGesture: Date?
    private var awaitingInitialLoad = false
    private var initialNavigation: WKNavigation?
    private var controllerName = ""
    private var loadToken = 0
    private var loadTask: Task<Void, Never>?
    private var tornDown = false
    /// Console lines left for this load: a page can post to the handler directly, bypassing the script's own cap.
    private var logBudget = CreativeWebController.logCapacity

    static let logCapacity = 2_000

    init(host: any AdRenderingHost) {
        self.host = host
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let parentProvider = ParentProvider()
        configuration.setURLSchemeHandler(SampleSchemeHandler(monitor: host.monitor) { parentProvider.parentID }, forURLScheme: SampleURL.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.parentProvider = parentProvider
        super.init()
        messageProxy.target = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = host.device.userAgent
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.allowsLinkPreview = false
        webView.isInspectable = true
        Self.makeTransparent(webView)
        let controller = configuration.userContentController
        controller.add(messageProxy, contentWorld: .page, name: BridgeMessage.handlerName)
        controller.add(messageProxy, contentWorld: .world(name: CreativeScripts.isolatedWorldName), name: BridgeMessage.gestureHandlerName)
    }

    private let parentProvider: ParentProvider

    // MARK: Loading

    /// Loads (or reloads) the creative: resets the scripts, the sandbox and the request bookkeeping.
    func load(_ content: Content) {
        guard !tornDown else { return }
        loadToken &+= 1
        let token = loadToken
        loadTask?.cancel()
        finishOpenRequests("The creative was reloaded before the load finished")
        self.content = content
        ledger = CreativeRequestLedger()
        logBudget = Self.logCapacity
        parentProvider.parentID = content.networkParentID
        lastGesture = nil
        awaitingInitialLoad = false
        initialNavigation = nil
        webView.stopLoading()

        let userContent = webView.configuration.userContentController
        userContent.removeAllUserScripts()
        userContent.removeAllContentRuleLists()
        userContent.addUserScript(WKUserScript(source: CreativeScripts.instrumentation, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                               in: .page))
        userContent.addUserScript(WKUserScript(source: CreativeScripts.gesture, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                               in: .world(name: CreativeScripts.isolatedWorldName)))
        if let environment = content.mraid {
            controllerName = "__ccinnMRAID_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            userContent.addUserScript(WKUserScript(source: CreativeScripts.mraid(environment: environment, controller: controllerName),
                                                   injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        } else {
            controllerName = ""
        }
        if content.blocksNetwork {
            userContent.addUserScript(WKUserScript(source: CreativeScripts.blockWebRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                                   in: .page))
        }
        if content.disableScroll {
            userContent.addUserScript(WKUserScript(source: CreativeScripts.noScroll, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        }

        loadTask = Task { [weak self] in
            var lists: [WKContentRuleList] = []
            if let mraidJS = try? await CreativeContentRules.mraidJS() { lists.append(mraidJS) }
            if content.blocksNetwork {
                do {
                    lists.append(try await CreativeContentRules.blockNetwork())
                } catch {
                    guard let self, token == self.loadToken else { return }
                    self.log(.html, .error, "The Simulated-mode sandbox is unavailable (\(error.localizedDescription)); the creative is not loaded")
                    self.onEvent?(.failed("The network sandbox could not be prepared, so the creative was not loaded."))
                    return
                }
            }
            guard let self, token == self.loadToken, !Task.isCancelled, !self.tornDown else { return }
            for list in lists { userContent.add(list) }
            self.awaitingInitialLoad = true
            self.initialNavigation = self.webView.loadHTMLString(content.document, baseURL: content.baseURL)
        }
    }

    /// MRAID exposure (0…100) from the shell's visible fraction.
    func updateExposure(_ percentage: Double) {
        guard !controllerName.isEmpty, percentage.isFinite else { return }
        callController("update(update)", arguments: ["update": ["exposure": min(100, max(0, percentage))]])
    }

    /// The container's own close control (chrome X, expanded-state close).
    func containerClose() {
        callController("containerClose()")
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        loadToken &+= 1
        loadTask?.cancel()
        loadTask = nil
        finishOpenRequests("The creative was removed before the load finished")
        onEvent = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let userContent = webView.configuration.userContentController
        userContent.removeAllScriptMessageHandlers()
        userContent.removeAllUserScripts()
        userContent.removeAllContentRuleLists()
        messageProxy.target = nil
    }

    /// Runs `body` with the MRAID controller bound to `controller` (the page world); errors are ignored.
    private func callController(_ body: String, arguments: [String: Any] = [:]) {
        guard !controllerName.isEmpty, !tornDown else { return }
        let script = "const controller = window[\(JSLiteral.string(controllerName))]; if (controller) { controller.\(body); }"
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    // MARK: Bridge

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !tornDown, let bridge = BridgeMessage.decode(message.body) else { return }
        let fromGestureWorld = message.name == BridgeMessage.gestureHandlerName
        if fromGestureWorld {
            if bridge == .gesture { lastGesture = Date() }
            return
        }
        let isMainFrame = message.frameInfo.isMainFrame
        switch bridge {
        case .gesture:
            // Only the isolated world reports gestures; the page cannot fake one.
            break
        case let .mraid(command, description):
            guard isMainFrame else { return }
            log(.mraid, .info, description)
            switch command {
            case let .open(url): onEvent?(.mraidOpen(url: url))
            case .other: break
            default: onEvent?(.mraidCommand(command))
            }
        case let .mraidError(message, action):
            guard isMainFrame else { return }
            log(.mraid, .warning, "error event: \(message)" + (action.isEmpty ? "" : " (\(action))"))
        case let .mraidState(state, customClose, size):
            guard isMainFrame else { return }
            onEvent?(.mraidState(state, customClose: customClose, size: size))
        case let .network(network):
            handle(network)
        case let .windowOpen(url):
            navigationAttempt(NavigationFacts(url: url, isMainFrame: isMainFrame, targetsNewWindow: true, isInitialDocument: false),
                              trigger: "window.open")
        case let .console(level, text):
            let mapped: RendererLogEntry.Level = switch level {
            case "error": .error
            case "warn": .warning
            default: .info
            }
            log(.html, mapped, "console.\(level): \(text)")
        }
    }

    private func handle(_ message: CreativeNetworkMessage) {
        guard let host, let content else { return }
        let monitor = host.monitor
        let parentID = content.networkParentID
        let record: CreativeRequestLedger.Record = { url, kind, blocked in
            monitor.recordCreativeRequest(url: url, kind: kind, blocked: blocked, parentID: parentID)
        }
        switch message {
        case let .start(rid, url, kind):
            if ledger.start(rid: rid, url: url, kind: kind, blocked: content.blocksNetwork, record: record) == .overflow { logOverflow() }
        case let .end(rid, status, bytes, error):
            let url = ledger.openURL(rid: rid)
            if let id = ledger.end(rid: rid) {
                let explained = error.map { Self.explain($0, url: url, page: content.baseURL) }
                monitor.finishRendererLoad(id, status: status, error: explained, responseBytes: bytes)
            }
        case let .timing(url, kind, status, bytes):
            switch ledger.timing(url: url, kind: kind, blocked: content.blocksNetwork, record: record) {
            case let .recorded(id): monitor.finishRendererLoad(id, status: status ?? 200, responseBytes: bytes)
            case .overflow: logOverflow()
            case .ignored: break
            }
        case .overflow:
            logOverflow()
        }
    }

    /// A failed http load from an https page was blocked as mixed content; say so (the page only sees "load error").
    nonisolated static func explain(_ error: String, url: String?, page: URL) -> String {
        guard page.scheme == "https", let url, URLText.scheme(url)?.lowercased() == "http" else { return error }
        return error + " (http content in an https page is blocked as mixed content, as an app's ATS / cleartext policy would)"
    }

    private func logOverflow() {
        log(.html, .warning, "The creative made more than \(CreativeRequestLedger.defaultCapacity) requests; further ones are not recorded")
    }

    private func finishOpenRequests(_ reason: String) {
        guard let monitor = host?.monitor else { return }
        for id in ledger.drainOpen() { monitor.finishRendererLoad(id, error: reason) }
    }

    /// A navigation the creative attempted (main frame, new window, `window.open`).
    private func navigationAttempt(_ facts: NavigationFacts, trigger: String) {
        switch NavigationClassifier.decide(facts, lastGesture: lastGesture, now: Date()) {
        case .allow, .ignore:
            break
        case let .click(url):
            log(.html, .info, "Click-through (\(trigger)): \(url)")
            onEvent?(.click(url: url, trigger: trigger))
        case let .autoRedirect(url):
            log(.html, .warning, "Auto-redirect without a user gesture blocked (\(trigger)): \(url)")
            host?.monitor.recordNavigation(url: url, trigger: "auto-redirect blocked (\(trigger), no user gesture)",
                                           source: content?.source ?? "creative", parentID: content?.networkParentID)
        }
    }

    private func log(_ origin: RendererLogOrigin, _ level: RendererLogEntry.Level, _ message: String) {
        guard logBudget > 0 else { return }
        logBudget -= 1
        let line = logBudget == 0 ? message + " (log limit reached: further output of this creative is not shown)" : message
        host?.rendererLog(RendererLogEntry(origin, level, line))
    }

    private static func makeTransparent(_ webView: WKWebView) {
        let selector = NSSelectorFromString("setDrawsBackground:")
        if webView.responds(to: selector) { webView.setValue(false, forKey: "drawsBackground") }
        webView.underPageBackgroundColor = .clear
    }
}

// MARK: - WebKit delegates

extension CreativeWebController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.absoluteString ?? ""
        let facts = NavigationFacts(url: url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                                    targetsNewWindow: navigationAction.targetFrame == nil,
                                    isInitialDocument: awaitingInitialLoad && url == content?.baseURL.absoluteString,
                                    currentURL: webView.url?.absoluteString)
        let decision = NavigationClassifier.decide(facts, lastGesture: lastGesture, now: Date())
        if decision == .allow {
            if facts.isMainFrame, awaitingInitialLoad { awaitingInitialLoad = false }
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        navigationAttempt(facts, trigger: facts.targetsNewWindow ? "target=_blank" : "navigation")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard let navigation, navigation === initialNavigation else { return }
        initialNavigation = nil
        callController("ready()")
        onEvent?(.loaded)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        initialLoadFailed(navigation, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        initialLoadFailed(navigation, error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log(.html, .error, "The creative's web content process terminated")
        onEvent?(.failed("The creative's web content process terminated."))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        navigationAttempt(NavigationFacts(url: navigationAction.request.url?.absoluteString ?? "", isMainFrame: false, targetsNewWindow: true,
                                          isInitialDocument: false), trigger: "new window")
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        log(.html, .warning, "alert(): \(message.prefix(500))")
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        log(.html, .warning, "confirm(): \(message.prefix(500)) → false")
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        log(.html, .warning, "prompt(): \(prompt.prefix(500)) → null")
        completionHandler(nil)
    }

    private func initialLoadFailed(_ navigation: WKNavigation?, _ error: any Error) {
        guard let navigation, navigation === initialNavigation else { return }
        initialNavigation = nil
        awaitingInitialLoad = false
        log(.html, .error, "The creative document failed to load: \(error.localizedDescription)")
        onEvent?(.failed(error.localizedDescription))
    }
}

/// Holds the network parent the scheme handler records under (the handler is created with the configuration, before the
/// first load sets it).
@MainActor
private final class ParentProvider {
    var parentID: UUID?
}

/// The user content controller retains its handlers; the proxy keeps that reference weak, so the controller can go away.
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: CreativeWebController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}
