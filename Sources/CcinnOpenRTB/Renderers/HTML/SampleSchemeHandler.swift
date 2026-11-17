import CcinnOpenRTBKit
import Foundation
import WebKit

/// Serves `ccinn-sample://` URLs (the built-in offline images and media) to creative web views, and records each load as
/// a local creative request. Nothing leaves the machine.
///
/// WebKit raises an exception if a task is answered after it was stopped, so every answer checks that the task is still
/// running (`active`), on the main actor where `stop` also runs.
@MainActor
final class SampleSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let maxBytes = 64 << 20

    private weak var monitor: NetworkMonitor?
    private let parentID: () -> UUID?
    private let samples: any SampleMediaProviding
    private var active: Set<ObjectIdentifier> = []

    init(monitor: NetworkMonitor, samples: any SampleMediaProviding = SampleMedia.shared, parentID: @escaping () -> UUID?) {
        self.monitor = monitor
        self.samples = samples
        self.parentID = parentID
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        active.insert(key)
        let url = urlSchemeTask.request.url
        let text = url?.absoluteString ?? ""
        let entryID = monitor?.recordCreativeRequest(url: text, kind: "sample", blocked: false, parentID: parentID())
        guard let url, let asset = SampleURL.parse(text) else {
            fail(urlSchemeTask, key: key, entryID: entryID, message: "Unknown sample \(text.prefix(120))")
            return
        }
        let samples = samples
        Task { [weak self] in
            do {
                let file = try await samples.fileURL(for: asset)
                let data = try await Self.read(file)
                self?.respond(urlSchemeTask, key: key, url: url, data: data, mimeType: asset.mimeType, entryID: entryID)
            } catch {
                self?.fail(urlSchemeTask, key: key, entryID: entryID, message: error.localizedDescription)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func respond(_ task: any WKURLSchemeTask, key: ObjectIdentifier, url: URL, data: Data, mimeType: String, entryID: UUID?) {
        guard active.remove(key) != nil else {
            // WebKit stopped the task (page gone or reloaded): the entry still gets an outcome.
            if let entryID { monitor?.finishRendererLoad(entryID, error: "Cancelled by the web view") }
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mimeType, "Content-Length": String(data.count),
                                                      "Access-Control-Allow-Origin": "*"])
        task.didReceive(response ?? URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
        if let entryID { monitor?.finishRendererLoad(entryID, status: 200, responseBytes: data.count, mimeType: mimeType) }
    }

    private func fail(_ task: any WKURLSchemeTask, key: ObjectIdentifier, entryID: UUID?, message: String) {
        if let entryID { monitor?.finishRendererLoad(entryID, error: message) }
        guard active.remove(key) != nil else { return }
        task.didFailWithError(URLError(.fileDoesNotExist))
    }

    nonisolated private static func read(_ file: URL) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes) ?? Data()
    }
}
