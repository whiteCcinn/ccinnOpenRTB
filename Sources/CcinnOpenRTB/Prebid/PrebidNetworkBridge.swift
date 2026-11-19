import CcinnOpenRTBKit
import Foundation
import RTBKit
import WebKit

/// Answers the page shim's network calls (`prebidNet`):
///
/// - `script`: Prebid.js's own files (the loader, its chunks, the manifest) from the library — the page's `integrity`
///   still checks them; any other script is refused (403), so no adapter loads code the app did not vet.
/// - `fetch`, `xhr`, `beacon`: bid requests, through the window's network monitor — recorded, sent in Simulated and Real
///   mode, never Offline — following redirects as a browser does, with the headers the browser adds (`Origin`, `Referer`,
///   `Sec-Fetch-*`). No cookies: the page is a fresh profile (and Safari, the iPhone's browser, sends no third-party
///   cookies anyway).
/// - `pixel` (a `no-cors` fetch): a tracker — recorded; sent only in Real mode.
@MainActor
final class PrebidNetworkBridge: NSObject, WKScriptMessageHandlerWithReply {
    /// The page being run: its URL (for the browser's headers) and where its scripts come from.
    struct Page {
        var url: URL
        var scripts: @MainActor (_ url: String) async throws -> Data
    }

    private let monitor: @MainActor () -> NetworkMonitor
    private let userAgent: @MainActor () -> String
    var page: Page?
    /// Called for every request the page made: its kind, URL and status (`nil`: it failed). The bidder is not known
    /// here: the timeline matches by URL.
    var onRequest: ((_ kind: String, _ url: String, _ status: Int?) -> Void)?

    init(monitor: @escaping @MainActor () -> NetworkMonitor, userAgent: @escaping @MainActor () -> String) {
        self.monitor = monitor
        self.userAgent = userAgent
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let page, let body = message.body as? [String: Any], let url = body["url"] as? String, let kind = body["kind"] as? String else {
            return (nil, "malformed request")
        }
        switch kind {
        case "script": return await script(url, page: page)
        case "pixel": return pixel(url)
        default: return await send(kind: kind, url: url, body: body, page: page)
        }
    }

    private func script(_ url: String, page: Page) async -> (Any?, String?) {
        do {
            let data = try await page.scripts(url)
            onRequest?("script", url, 200)
            return (Self.reply(status: 200, headers: [["Content-Type", "application/javascript"]], body: data, url: url), nil)
        } catch PrebidLibrary.Failure.notPrebid {
            onRequest?("script", url, 403)
            return (Self.reply(status: 403, headers: [], body: Data(), url: url, blocked: true), nil)
        } catch {
            onRequest?("script", url, nil)
            return (nil, ClientModel.message(for: error))
        }
    }

    private func pixel(_ url: String) -> (Any?, String?) {
        let request = TrackerRequest(category: .event, trigger: "Prebid pixel", source: "prebid › page", template: url, url: url)
        monitor().dispatch(request, userAgent: userAgent())
        onRequest?("pixel", url, nil)
        return (Self.reply(status: 200, headers: [], body: Data(), url: url), nil)
    }

    private func send(kind: String, url: String, body: [String: Any], page: Page) async -> (Any?, String?) {
        guard let target = URL(string: url), target.scheme == "https" || target.scheme == "http" else { return (nil, "only http(s) is answered") }
        let method = ((body["method"] as? String) ?? "GET").uppercased()
        var pageHeaders: [String: String] = [:]
        for (name, value) in (body["headers"] as? [String: Any]) ?? [:] { pageHeaders[name] = String(describing: value) }
        let headers = PrebidFetchHeaders.headers(for: target, method: method, kind: kind, page: page.url, pageHeaders: pageHeaders)
        let payload = (body["body"] as? String).flatMap { Data(base64Encoded: $0) }
        let request = ComposedRequest(url: url, method: method, headers: headers, body: payload, redirects: .all, purpose: .bidRequest,
                                      trigger: kind == "beacon" ? "Prebid beacon" : "Prebid bid request", source: "prebid › page")
        do {
            let response = try await monitor().send(request, userAgent: userAgent())
            onRequest?(kind, url, response.status)
            let headerPairs = HTTPHeaders.sorted(response.headers).map { [$0.name, $0.value] }
            return (Self.reply(status: response.status, headers: headerPairs, body: response.body, url: response.url.absoluteString), nil)
        } catch {
            onRequest?(kind, url, nil)
            return (nil, ClientModel.message(for: error))
        }
    }

    private static func reply(status: Int, headers: [[String]], body: Data, url: String, blocked: Bool = false) -> [String: Any] {
        ["status": status, "statusText": HTTPHeaders.reasonPhrase(status), "headers": headers, "body": body.base64EncodedString(), "url": url,
         "blocked": blocked]
    }
}
