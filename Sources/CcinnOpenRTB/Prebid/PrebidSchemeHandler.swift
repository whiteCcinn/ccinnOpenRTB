import Foundation
import WebKit

/// Serves the Prebid page on `ccinn-prebid://<publisher host>/`: `/index.html` (the page) and
/// `/prebid/<version>/<dist or metadata path>` (Prebid.js, from `PrebidLibrary`). Same origin, so the loader's chunk
/// scripts keep their `integrity` and `crossorigin`; anything else is a 404.
@MainActor
final class PrebidSchemeHandler: NSObject, WKURLSchemeHandler {
    var page = ""
    private let library: PrebidLibrary
    private var stopped: Set<ObjectIdentifier> = []

    init(library: PrebidLibrary) {
        self.library = library
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path
        if path == "/" || path == "/index.html" {
            respond(task, url: url, status: 200, type: "text/html; charset=utf-8", body: Data(page.utf8))
            return
        }
        let parts = path.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "prebid" else {
            respond(task, url: url, status: 404, type: "text/plain", body: Data("not found".utf8))
            return
        }
        let id = ObjectIdentifier(task)
        let library = library
        Task { @MainActor in
            do {
                let data = try await library.file(version: parts[1], path: parts[2])
                guard !self.stopped.contains(id) else { return }
                let type = parts[2].hasSuffix(".json") ? "application/json" : "application/javascript; charset=utf-8"
                self.respond(task, url: url, status: 200, type: type, body: data)
            } catch {
                guard !self.stopped.contains(id) else { return }
                self.respond(task, url: url, status: 502, type: "text/plain", body: Data(error.localizedDescription.utf8))
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int, type: String, body: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": type, "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]) else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}
