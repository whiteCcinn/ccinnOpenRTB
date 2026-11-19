import CcinnOpenRTBKit
import Foundation
import RTBKit
import WebKit

/// Answers the page shim's network calls (`prebidNet`) with the window's network monitor: bid requests (`fetch`, XHR,
/// `sendBeacon`) are composed requests — recorded, sent in Simulated and Real mode, never Offline — following redirects
/// as a browser does; `no-cors` pixels are trackers (recorded; sent only in Real mode). Only http(s) is answered.
@MainActor
final class PrebidNetworkBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let monitor: @MainActor () -> NetworkMonitor
    private let userAgent: @MainActor () -> String
    /// The page's cookie jar (the Sync tab's, so bidders see the ids the syncs stored); `nil` sends none.
    private let cookies: @MainActor () -> CookieSession?
    /// Called for every request the page made (the bidder is not known here: the timeline matches by URL).
    var onRequest: ((_ kind: String, _ url: String, _ status: Int?) -> Void)?

    init(monitor: @escaping @MainActor () -> NetworkMonitor, userAgent: @escaping @MainActor () -> String,
         cookies: @escaping @MainActor () -> CookieSession? = { nil }) {
        self.monitor = monitor
        self.userAgent = userAgent
        self.cookies = cookies
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let url = body["url"] as? String, let kind = body["kind"] as? String else {
            return (nil, "malformed request")
        }
        let method = (body["method"] as? String) ?? "GET"
        var headers: [String: String] = [:]
        for (name, value) in (body["headers"] as? [String: Any]) ?? [:] { headers[name] = String(describing: value) }
        let payload = (body["body"] as? String).flatMap { Data(base64Encoded: $0) }
        if kind == "pixel" {
            let request = TrackerRequest(category: .event, trigger: "Prebid pixel", source: "prebid › page", template: url, url: url)
            monitor().dispatch(request, userAgent: userAgent())
            onRequest?(kind, url, nil)
            return (["status": 200, "statusText": "", "headers": [[String]](), "body": "", "url": url], nil)
        }
        let request = ComposedRequest(url: url, method: method, headers: headers, body: payload, redirects: .all, purpose: .bidRequest,
                                      cookies: cookies(), trigger: kind == "beacon" ? "Prebid beacon" : "Prebid bid request", source: "prebid › page")
        do {
            let response = try await monitor().send(request, userAgent: userAgent())
            onRequest?(kind, url, response.status)
            let headerPairs = HTTPHeaders.sorted(response.headers).map { [$0.name, $0.value] }
            return (["status": response.status, "statusText": HTTPHeaders.reasonPhrase(response.status), "headers": headerPairs,
                     "body": response.body.base64EncodedString(), "url": response.url.absoluteString], nil)
        } catch {
            onRequest?(kind, url, nil)
            return (nil, ClientModel.message(for: error))
        }
    }
}
