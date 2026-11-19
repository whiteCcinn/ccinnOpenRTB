import CcinnOpenRTBKit
import Foundation
import RTBKit
import WebKit

/// Answers the page shim's network calls (`prebidNet`) for the page being run (a call from any other page, such as one
/// being replaced, is refused):
///
/// - `script`: Prebid.js's own files (the loader, its chunks, the manifest) from the library — the page's `integrity`
///   still checks them; any other script URL is refused (403). (Page code can still fetch data and evaluate it, as on a
///   live site: what is guaranteed is that every byte comes through the gate.)
/// - `fetch`, `xhr`, `beacon`: requests through the window's network monitor — recorded, sent in Simulated and Real mode,
///   never Offline — with the browser's rules: http from the https page is mixed content (refused, the Mac's own
///   loopback aside); a cross-origin request that needs one gets a CORS preflight (`OPTIONS`, recorded), and its
///   response reaches the page only if the bidder's CORS headers allow it — otherwise the page sees a network error, as
///   in Safari, and `onRequest` says why. The headers are the browser's (`Origin`, `Referer`, `Sec-Fetch-*`, Chrome's
///   client hints). No cookies: the page is a fresh profile (and Safari, the iPhone's browser, sends no third-party
///   cookies anyway).
/// - A `no-cors` GET (a pixel) is a tracker: recorded, sent only in Real mode; the page gets an opaque response.
@MainActor
final class PrebidNetworkBridge: NSObject, WKScriptMessageHandlerWithReply {
    /// The page being run: its URL (for the browser's headers), its run, its client hints and where its scripts come from.
    struct Page {
        var url: URL
        var run: String
        var clientHints: [String: String] = [:]
        var scripts: @MainActor (_ url: String) async throws -> Data
    }

    /// What became of one of the page's requests.
    struct Outcome: Sendable, Equatable {
        var kind: String
        var url: String
        /// `nil`: no response reached the page.
        var status: Int?
        /// Why the browser would not let the page have it (CORS, mixed content), or why it failed.
        var problem: String?
    }

    /// A body the page may send at most (the monitor keeps at most this much of it too).
    static let maxBodyBytes = 8 * 1024 * 1024

    private let monitor: NetworkMonitor
    private let userAgent: @MainActor () -> String
    var page: Page?
    var onRequest: ((Outcome) -> Void)?

    init(monitor: NetworkMonitor, userAgent: @escaping @MainActor () -> String) {
        self.monitor = monitor
        self.userAgent = userAgent
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let url = body["url"] as? String, let kind = body["kind"] as? String else {
            return (nil, "malformed request")
        }
        guard let page, body["run"] as? String == page.run else { return (nil, "This page is no longer running.") }
        if kind == "script" { return await script(url, page: page) }
        return await send(kind: kind, url: url, body: body, page: page)
    }

    private func script(_ url: String, page: Page) async -> (Any?, String?) {
        do {
            let data = try await page.scripts(url)
            report(page, Outcome(kind: "script", url: url, status: 200))
            return (Self.reply(status: 200, headers: [["Content-Type", "application/javascript"]], body: data, url: url), nil)
        } catch PrebidLibrary.Failure.notPrebid {
            report(page, Outcome(kind: "script", url: url, status: 403, problem: "Only Prebid.js's own scripts run on this page."))
            return (Self.reply(status: 403, headers: [], body: Data(), url: url, blocked: true), nil)
        } catch {
            report(page, Outcome(kind: "script", url: url, status: nil, problem: ClientModel.message(for: error)))
            return (nil, ClientModel.message(for: error))
        }
    }

    private func send(kind: String, url: String, body: [String: Any], page: Page) async -> (Any?, String?) {
        func refuse(_ problem: String) -> (Any?, String?) {
            report(page, Outcome(kind: kind, url: url, status: nil, problem: problem))
            return (nil, problem)
        }
        guard let target = URL(string: url), target.scheme == "https" || target.scheme == "http", let pageOrigin = PrebidFetchHeaders.origin(of: page.url) else {
            return refuse("Only http(s) is answered.")
        }
        guard !PrebidCORS.isMixedContent(target, page: page.url) else {
            return refuse("Mixed content: the https page cannot load \(url.prefix(200)) over http; Safari blocks it.")
        }
        let encoded = body["body"] as? String
        guard (encoded?.utf8.count ?? 0) <= Self.maxBodyBytes / 3 * 4 + 4 else { return refuse("The body is larger than \(Self.maxBodyBytes / 1_048_576) MiB.") }
        let method = ((body["method"] as? String) ?? "GET").uppercased()
        var pageHeaders: [String: String] = [:]
        for (name, value) in (body["headers"] as? [String: Any]) ?? [:] { pageHeaders[name] = String(describing: value) }
        let mode = (body["mode"] as? String) ?? "cors"
        let credentials = PrebidCORS.Credentials(page: body["credentials"] as? String)
        let crossOrigin = PrebidFetchHeaders.origin(of: target) != pageOrigin
        if crossOrigin && mode == "same-origin" { return refuse("A same-origin request cannot go to another origin.") }
        if crossOrigin && mode == "no-cors" && (method == "GET" || method == "HEAD") { return pixel(url, page: page) }

        if crossOrigin && mode == "cors" && PrebidCORS.needsPreflight(method: method, headers: pageHeaders) {
            let unsafe = PrebidCORS.unsafeHeaderNames(pageHeaders)
            // The preflight's headers are the browser's own (Access-Control-Request-* are forbidden to the page).
            let preflightHeaders = PrebidFetchHeaders.headers(for: target, method: "OPTIONS", mode: "cors", page: page.url, pageHeaders: [:],
                                                              clientHints: page.clientHints)
                .merging(PrebidCORS.preflightHeaders(method: method, unsafeNames: unsafe)) { _, preflight in preflight }
            let preflight = ComposedRequest(url: url, method: "OPTIONS", headers: preflightHeaders, body: nil, redirects: .none, purpose: .bidRequest,
                                            trigger: "CORS preflight", source: "prebid › page")
            do {
                let answer = try await monitor.send(preflight, userAgent: userAgent())
                if let problem = PrebidCORS.preflightProblem(status: answer.status, headers: answer.headers, origin: pageOrigin, method: method,
                                                             unsafeNames: unsafe, credentials: credentials) {
                    return refuse("CORS: \(problem).")
                }
            } catch {
                return refuse("CORS: the preflight failed: \(ClientModel.message(for: error))")
            }
        }

        let headers = PrebidFetchHeaders.headers(for: target, method: method, mode: mode, page: page.url, pageHeaders: pageHeaders,
                                                 clientHints: page.clientHints)
        let request = ComposedRequest(url: url, method: method, headers: headers, body: encoded.flatMap { Data(base64Encoded: $0) }, redirects: .all,
                                      purpose: .bidRequest, trigger: kind == "beacon" ? "Prebid beacon" : "Prebid bid request", source: "prebid › page")
        let response: ComposedResponse
        do {
            response = try await monitor.send(request, userAgent: userAgent())
        } catch {
            return refuse(ClientModel.message(for: error))
        }
        if crossOrigin && mode == "no-cors" {
            report(page, Outcome(kind: kind, url: url, status: response.status))
            return (Self.reply(status: 0, headers: [], body: Data(), url: "", type: "opaque"), nil)
        }
        if crossOrigin, let problem = PrebidCORS.responseProblem(headers: response.headers, origin: pageOrigin, credentials: credentials) {
            report(page, Outcome(kind: kind, url: url, status: response.status, problem: "CORS: \(problem); the page does not get the response."))
            return (nil, "CORS: \(problem)")
        }
        report(page, Outcome(kind: kind, url: url, status: response.status))
        let exposed = PrebidCORS.exposedHeaders(response.headers, crossOrigin: crossOrigin, credentials: credentials)
        return (Self.reply(status: response.status, headers: HTTPHeaders.sorted(exposed).map { [$0.name, $0.value] }, body: response.body,
                           url: response.url.absoluteString, type: crossOrigin ? "cors" : "basic", redirected: response.chain.count > 1), nil)
    }

    private func pixel(_ url: String, page: Page) -> (Any?, String?) {
        let request = TrackerRequest(category: .event, trigger: "Prebid pixel", source: "prebid › page", template: url, url: url)
        monitor.dispatch(request, userAgent: userAgent())
        report(page, Outcome(kind: "pixel", url: url, status: nil))
        return (Self.reply(status: 0, headers: [], body: Data(), url: "", type: "opaque"), nil)
    }

    /// Only for the page still being run: a refusal or an answer that arrives after the page was replaced says nothing.
    private func report(_ page: Page, _ outcome: Outcome) {
        guard self.page?.run == page.run else { return }
        onRequest?(outcome)
    }

    private static func reply(status: Int, headers: [[String]], body: Data, url: String, blocked: Bool = false, type: String = "basic",
                              redirected: Bool = false) -> [String: Any] {
        ["status": status, "statusText": HTTPHeaders.reasonPhrase(status), "headers": headers, "body": body.base64EncodedString(), "url": url,
         "blocked": blocked, "type": type, "redirected": redirected]
    }
}
