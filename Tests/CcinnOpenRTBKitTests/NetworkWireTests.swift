import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTBKit

/// The monitor over the real transport against a loopback server: what is recorded is what went over the wire.
@MainActor
@Suite("Network on the wire", .serialized)
struct NetworkWireTests {
    private func lowercased(_ headers: [String: String]) -> [String: String] {
        Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
    }

    @Test func recordedRequestHeadersAreTheHeadersOnTheWire() async throws {
        let server = try LoopbackHTTPServer { request in
            request.path == "/imp" ? .redirect(to: "/pixel") : .text("<VAST version=\"4.2\"/>", type: "application/xml")
        }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        monitor.mode = .real
        _ = try await monitor.fetchContent("http://127.0.0.1:\(port)/vast", trigger: "VAST tag", source: "VAST", parentID: nil, userAgent: deviceUA)
        monitor.dispatch(tracker(.impression, "http://127.0.0.1:\(port)/imp"), userAgent: deviceUA)
        await monitor.waitUntilIdle()

        let entries = monitor.liveEntries
        #expect(entries.count == 3, "content, tracker, redirect hop")
        #expect(server.requests.count == 3)
        for (entry, request) in zip(entries, server.requests) {
            #expect(entry.requestHeadersAsSent, "\(entry.url)")
            #expect(lowercased(entry.requestHeaders) == request.headers, "\(entry.url): recorded \(entry.requestHeaders), wire \(request.headers)")
            let curl = CurlCommand.make(for: entry)
            for (name, value) in entry.requestHeaders { #expect(curl.contains(CurlCommand.quote("\(name): \(value)"))) }
        }
        let har = try #require(try JSONSerialization.jsonObject(with: monitor.harData()) as? [String: Any])
        let harEntries = try #require((har["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        for (harEntry, request) in zip(harEntries, server.requests) {
            let headers = try #require((harEntry["request"] as? [String: Any])?["headers"] as? [[String: String]])
            #expect(Dictionary(headers.map { (($0["name"] ?? "").lowercased(), $0["value"] ?? "") }) { first, _ in first } == request.headers)
            #expect((harEntry["_ccinn"] as? [String: Any])?["requestHeadersAsSent"] as? Bool == true)
        }
        // Explicit, from the monitor (the simulated device's language), not CFNetwork's guess from the Mac's locale.
        #expect(server.requests.allSatisfy { $0.header("Accept-Language") == NetworkMonitor.defaultAcceptLanguage })
        #expect(server.requests.allSatisfy { $0.header("User-Agent") == deviceUA })
    }

    @Test func theMonitorsLanguageIsSentAndRecorded() async throws {
        let server = try LoopbackHTTPServer { _ in .text("ok") }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        monitor.acceptLanguage = "de-DE,de;q=0.9"
        _ = try await monitor.fetchContent("http://127.0.0.1:\(port)/x", trigger: "image", source: "Native", parentID: nil, userAgent: deviceUA)
        #expect(server.requests.first?.header("Accept-Language") == "de-DE,de;q=0.9")
        #expect(monitor.liveEntries.first.flatMap { HTTPHeaders.value("Accept-Language", in: $0.requestHeaders) } == "de-DE,de;q=0.9")
    }

    /// A Simulated-mode tracker never ran: its headers are the ones it would have sent, and say so.
    @Test func headersOfARequestNeverSentAreMarkedPlanned() {
        let monitor = NetworkMonitor(transport: FailingTransport(), publishInterval: .zero)
        let id = monitor.dispatch(tracker(.impression, "https://t.example/imp"), userAgent: deviceUA)
        let entry = monitor.entry(id: id)
        #expect(entry?.requestHeadersAsSent == false)
    }
}
