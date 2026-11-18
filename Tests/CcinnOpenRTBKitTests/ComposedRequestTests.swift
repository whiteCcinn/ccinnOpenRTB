import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTBKit

private let endpoint = "https://ssp.example/openrtb2/auction"
private let bidRequestJSON = #"{"id":"req-1","imp":[{"id":"1","video":{"w":640,"h":360},"rwdd":1}]}"#
private let bidResponseJSON = #"{"id":"req-1","seatbid":[{"bid":[{"id":"b1","impid":"1","price":1.5,"mtype":2,"adm":"<VAST/>"}]}]}"#

private func composed(_ url: String = endpoint, method: String = "POST", headers: [String: String] = ["Content-Type": "application/json"],
                      body: String? = bidRequestJSON) -> ComposedRequest {
    ComposedRequest(url: url, method: method, headers: headers, body: body.map { Data($0.utf8) })
}

/// The header named `name` (any case): exactly one may be present.
private func headerValues(_ name: String, in headers: [String: String]) -> [String] {
    headers.filter { $0.key.lowercased() == name.lowercased() }.map(\.value)
}

@Suite("Dispatch policy: bid requests")
struct BidRequestDispatchPolicyTests {
    /// The user typed the URL and pressed Send: it goes out in Simulated and Real mode alike (it is not a tracker).
    @Test(arguments: [TrackingMode.simulated, .real])
    func aBidRequestIsSentInEitherMode(mode: TrackingMode) {
        #expect(DispatchPolicy.permit(for: .bidRequest, isScript: false, mode: mode) != nil)
    }

    /// Offline loads nothing: the bid request is recorded and not sent.
    @Test(arguments: [TrackingMode.simulated, .real])
    func offlineRecordsABidRequest(mode: TrackingMode) {
        #expect(DispatchPolicy.action(for: .bidRequest, isScript: false, mode: mode, offline: true)
            == .record(.blocked, .offline, note: DispatchPolicy.offlineNote))
        #expect(DispatchPolicy.permit(for: .bidRequest, isScript: false, mode: mode, offline: true, destination: .local) == nil)
    }
}

@Suite("HTTP headers: merge")
struct HTTPHeaderMergeTests {
    /// A user's `user-agent` replaces the monitor's `User-Agent`: one header, never two that URLSession picks between.
    @Test func overridesAreCaseInsensitive() {
        let merged = HTTPHeaders.merged(["User-Agent": "Device/1", "Accept": "*/*", "Accept-Language": "en-US"],
                                        overriddenBy: ["user-agent": "Custom/2", "ACCEPT": "application/json", "X-Extra": "1"])
        #expect(headerValues("User-Agent", in: merged) == ["Custom/2"])
        #expect(headerValues("Accept", in: merged) == ["application/json"])
        #expect(merged["Accept-Language"] == "en-US")
        #expect(merged["X-Extra"] == "1")
        #expect(merged.count == 4)
    }

    @Test func removingIsCaseInsensitive() {
        let kept = HTTPHeaders.removing(["authorization", "Cookie"], from: ["Authorization": "Bearer t", "cookie": "a=1", "Content-Type": "x"])
        #expect(kept == ["Content-Type": "x"])
    }
}

@MainActor
@Suite("Network monitor: composed requests")
struct ComposedRequestMonitorTests {
    @Test func aBidRequestIsSentInSimulatedModeAndRecordedWithItsBody() async throws {
        let clock = ManualClock()
        let transport = FakeTransport(clock: clock, latency: 0.042)
        transport.respond(endpoint, headers: ["Content-Type": "application/json"], body: bidResponseJSON)
        let monitor = makeMonitor(transport: transport, clock: clock)
        monitor.mode = .simulated

        let response = try await monitor.send(composed(headers: ["Content-Type": "application/json", "x-openrtb-version": "2.6"]),
                                              userAgent: deviceUA)

        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == bidResponseJSON)
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(abs(response.duration - 0.042) < 1e-6)
        #expect(response.timings?.wait != nil)
        let sent = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(sent.method == "POST")
        #expect(sent.body == Data(bidRequestJSON.utf8))
        #expect(sent.headers["x-openrtb-version"] == "2.6")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(headerValues("User-Agent", in: sent.headers) == [deviceUA])
        #expect(sent.headers["Accept-Language"] == NetworkMonitor.defaultAcceptLanguage)

        let entry = try #require(monitor.entry(id: response.entryID))
        #expect(entry.category == .bidRequest)
        #expect(entry.method == "POST")
        #expect(entry.delivery == .network)
        #expect(entry.state == .completed(status: 200))
        #expect(entry.sessionMode == .simulated)
        #expect(entry.trigger == "bid request")
        #expect(entry.requestBodyBytes == bidRequestJSON.utf8.count)
        #expect(monitor.requestBody(for: entry.id) == Data(bidRequestJSON.utf8))
        #expect(monitor.responseBody(for: entry.id) == Data(bidResponseJSON.utf8))
        #expect(response.responseEntryID == entry.id)
    }

    @Test func theUsersHeadersReplaceTheMonitorsWhateverTheirCase() async throws {
        let transport = FakeTransport()
        transport.respond(endpoint, body: "{}")
        let monitor = makeMonitor(transport: transport)

        _ = try await monitor.send(composed(headers: ["user-agent": "Exchange/1.0", "accept": "application/json"]), userAgent: deviceUA)

        let sent = try #require(transport.requests.first)
        #expect(headerValues("User-Agent", in: sent.headers) == ["Exchange/1.0"])
        #expect(headerValues("Accept", in: sent.headers) == ["application/json"])
    }

    /// A 400 with an error body is what the user needs to see: a result, not a failure.
    @Test(arguments: [204, 400, 500])
    func anyStatusIsAResult(status: Int) async throws {
        let transport = FakeTransport()
        transport.respond(endpoint, status: status, body: status == 204 ? "" : #"{"error":"bad imp"}"#)
        let monitor = makeMonitor(transport: transport)

        let response = try await monitor.send(composed(), userAgent: deviceUA)

        #expect(response.status == status)
        #expect(response.body.isEmpty == (status == 204))
        #expect(monitor.entry(id: response.entryID)?.state == .completed(status: status))
    }

    @Test func aGETSendsNoBody() async throws {
        let transport = FakeTransport()
        transport.respond(endpoint, body: "{}")
        let monitor = makeMonitor(transport: transport)

        let response = try await monitor.send(composed(method: "get"), userAgent: deviceUA)

        let sent = try #require(transport.requests.first)
        #expect(sent.method == "GET")
        #expect(sent.body == nil)
        #expect(monitor.entry(id: response.entryID)?.requestBodyBytes == nil)
        #expect(monitor.requestBody(for: response.entryID) == nil)
    }

    @Test func offlineRecordsTheRequestAndSendsNothing() async throws {
        let transport = FailingTransport()
        let monitor = makeMonitor(transport: transport)
        monitor.offline = true

        let error = await #expect(throws: NetworkMonitorError.self) { try await monitor.send(composed(), userAgent: deviceUA) }

        guard case let .offline(entryID)? = error else {
            Issue.record("expected .offline, got \(String(describing: error))")
            return
        }
        let entry = try #require(monitor.entry(id: entryID))
        #expect(entry.category == .bidRequest)
        #expect(entry.delivery == .offline)
        #expect(entry.state == .blocked)
        #expect(entry.requestBodyBytes == bidRequestJSON.utf8.count)
        #expect(transport.callCount == 0)
    }

    @Test(arguments: ["data:application/json,{}", "ftp://ssp.example/bid", "ccinn-sample://image/icon.png"])
    func onlyHTTPAndHTTPSAreSent(url: String) async throws {
        let transport = FailingTransport()
        let monitor = makeMonitor(transport: transport)

        let error = await #expect(throws: NetworkMonitorError.self) { try await monitor.send(composed(url), userAgent: deviceUA) }

        #expect(error == .unsupportedScheme(URLText.scheme(url) ?? ""))
        #expect(transport.callCount == 0)
        #expect(monitor.liveEntries.count == 1)
        #expect(monitor.liveEntries.first?.isFailure == true)
    }

    /// Not a tracker: leaving Real mode (as Render, Reset and Lose do with trackers) lets it finish.
    @Test func leavingRealModeDoesNotCancelIt() async throws {
        let transport = FakeTransport()
        transport.respond(endpoint, body: bidResponseJSON, delay: .milliseconds(150))
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real

        let sending = Task { try await monitor.send(composed(), userAgent: deviceUA) }
        try await Task.sleep(for: .milliseconds(30))
        monitor.mode = .simulated
        monitor.cancelInFlightTrackers(reason: "a new render started")

        #expect(try await sending.value.status == 200)
    }

    @Test func goingOfflineCancelsIt() async throws {
        let transport = FakeTransport()
        transport.respond(endpoint, body: bidResponseJSON, delay: .seconds(5))
        let monitor = makeMonitor(transport: transport)

        let sending = Task { try await monitor.send(composed(), userAgent: deviceUA) }
        try await Task.sleep(for: .milliseconds(30))
        monitor.offline = true

        await #expect(throws: NetworkMonitorError.cancelled(NetworkMonitor.offlineCancellation)) { try await sending.value }
        #expect(monitor.liveEntries.first?.isFailure == true)
    }

    @Test func theCallerCanCancelIt() async throws {
        let transport = FakeTransport()
        transport.respond(endpoint, body: bidResponseJSON, delay: .seconds(5))
        let monitor = makeMonitor(transport: transport)

        let sending = Task { try await monitor.send(composed(), userAgent: deviceUA) }
        try await Task.sleep(for: .milliseconds(30))
        sending.cancel()

        await #expect(throws: (any Error).self) { try await sending.value }
        await monitor.waitUntilIdle()
        #expect(monitor.inFlightCount == 0)
        #expect(monitor.liveEntries.first?.state != .pending)
    }

    // MARK: Redirects (RFC 9110 §15.4)

    /// 307 and 308 repeat the method and the body; same-origin hops keep the user's credentials.
    @Test(arguments: [307, 308])
    func aTemporaryOrPermanentRedirectRepeatsThePOST(status: Int) async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "/v2/auction", status: status)
        transport.respond("https://ssp.example/v2/auction", body: bidResponseJSON)
        let monitor = makeMonitor(transport: transport)

        let response = try await monitor.send(composed(headers: ["Content-Type": "application/json", "Authorization": "Bearer t"]),
                                              userAgent: deviceUA)

        #expect(response.status == 200)
        #expect(response.url.absoluteString == "https://ssp.example/v2/auction")
        let hop = try #require(transport.requests.last)
        #expect(transport.requests.count == 2)
        #expect(hop.method == "POST")
        #expect(hop.body == Data(bidRequestJSON.utf8))
        #expect(hop.headers["Authorization"] == "Bearer t")
        #expect(hop.headers["Content-Type"] == "application/json")
        let hopEntry = try #require(monitor.entry(id: response.responseEntryID))
        #expect(hopEntry.parentID == response.entryID)
        #expect(hopEntry.method == "POST")
        #expect(hopEntry.category == .bidRequest)
        #expect(hopEntry.requestBodyBytes == bidRequestJSON.utf8.count)
        #expect(monitor.requestBody(for: hopEntry.id) == Data(bidRequestJSON.utf8))
    }

    /// A hop to another origin never carries the user's credentials (Fetch: "remove `Authorization`" on a cross-origin
    /// redirect; a hand-written `Cookie` is a credential too).
    @Test func aCrossOriginHopDropsCredentials() async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "https://other.example/auction", status: 307)
        transport.respond("https://other.example/auction", body: bidResponseJSON)
        let monitor = makeMonitor(transport: transport)

        _ = try await monitor.send(composed(headers: ["Content-Type": "application/json", "authorization": "Bearer t", "Cookie": "s=1",
                                                      "Proxy-Authorization": "Basic x", "x-openrtb-version": "2.6"]),
                                   userAgent: deviceUA)

        let hop = try #require(transport.requests.last)
        #expect(headerValues("Authorization", in: hop.headers).isEmpty)
        #expect(headerValues("Cookie", in: hop.headers).isEmpty)
        #expect(headerValues("Proxy-Authorization", in: hop.headers).isEmpty)
        #expect(hop.headers["x-openrtb-version"] == "2.6")
        #expect(hop.body == Data(bidRequestJSON.utf8))
    }

    /// 303, and 301 / 302 after a POST, continue as a GET without the body or the headers that describe it.
    @Test(arguments: [301, 302, 303])
    func aSeeOtherRedirectBecomesAGET(status: Int) async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "https://ssp.example/result", status: status)
        transport.respond("https://ssp.example/result", body: bidResponseJSON)
        let monitor = makeMonitor(transport: transport)

        let response = try await monitor.send(composed(headers: ["Content-Type": "application/json", "Content-Encoding": "identity",
                                                                 "x-openrtb-version": "2.6"]),
                                              userAgent: deviceUA)

        let hop = try #require(transport.requests.last)
        #expect(hop.method == "GET")
        #expect(hop.body == nil)
        #expect(headerValues("Content-Type", in: hop.headers).isEmpty)
        #expect(headerValues("Content-Encoding", in: hop.headers).isEmpty)
        #expect(hop.headers["x-openrtb-version"] == "2.6")
        let hopEntry = try #require(monitor.entry(id: response.responseEntryID))
        #expect(hopEntry.method == "GET")
        #expect(hopEntry.requestBodyBytes == nil)
        #expect(monitor.entry(id: response.entryID)?.method == "POST")
    }

    /// Trackers keep their own behaviour: a redirected GET tracker hop is a GET with the monitor's headers.
    @Test func trackerRedirectsAreUnchanged() async throws {
        let transport = FakeTransport()
        transport.redirect("https://dsp.example/win", to: "https://cdn.example/px", status: 307)
        transport.respond("https://cdn.example/px", body: "")
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real

        monitor.dispatch(tracker(.win, "https://dsp.example/win"), userAgent: deviceUA)
        await monitor.waitUntilIdle()

        #expect(transport.requests.map(\.method) == ["GET", "GET"])
        #expect(transport.requests.allSatisfy { $0.body == nil })
        #expect(monitor.liveEntries.allSatisfy { $0.method == "GET" })
    }
}

@Suite("Composed requests on the wire", .serialized)
struct ComposedRequestWireTests {
    /// The real transport puts the method, the body and the user's headers on the wire.
    @MainActor
    @Test func theBodyReachesTheServer() async throws {
        let server = try LoopbackHTTPServer { _ in .text(bidResponseJSON, type: "application/json") }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        let url = "http://127.0.0.1:\(port)/openrtb2/auction"

        let response = try await monitor.send(composed(url, headers: ["Content-Type": "application/json", "x-openrtb-version": "2.6"]),
                                              userAgent: deviceUA)

        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == bidResponseJSON)
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.path == "/openrtb2/auction")
        #expect(request.body == Data(bidRequestJSON.utf8))
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("x-openrtb-version") == "2.6")
        #expect(request.header("User-Agent") == deviceUA)
        // The headers recorded are the ones the transport reports as sent.
        #expect(monitor.entry(id: response.entryID)?.requestHeadersAsSent == true)
    }
}

@Suite("Copy as curl and HAR: request bodies")
struct RequestBodyExportTests {
    @Test func curlSendsTheBodyVerbatimWithNewlinesAndQuotes() {
        let body = "{\n  \"site\": \"it's\"\n}"
        let command = CurlCommand.make(url: endpoint, method: "POST", headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        #expect(command == #"curl --globoff -H 'Content-Type: application/json' --data-binary '{"# + "\n" + #"  "site": "it'\''s""# + "\n"
            + #"}' --url 'https://ssp.example/openrtb2/auction'"#)
    }

    /// A raw control character cannot be in JSON text and must not reach a terminal: written as its JSON escape.
    @Test func curlEscapesControlCharactersOtherThanWhitespace() {
        let command = CurlCommand.make(url: endpoint, method: "POST", body: Data("{\"a\":\"x\u{1B}[31m\u{0}\"}\t".utf8))
        #expect(command.contains(#"--data-binary '{"a":"x\u001B[31m\u0000"}"# + "\t'"))
        #expect(!command.contains("\u{1B}"))
    }

    @Test func curlKeepsAMethodOtherThanTheOneTheBodyImplies() {
        #expect(CurlCommand.make(url: endpoint, method: "PUT", body: Data("x".utf8)).contains("-X 'PUT'"))
        #expect(!CurlCommand.make(url: endpoint, method: "POST", body: Data("x".utf8)).contains("-X"))
        #expect(CurlCommand.make(url: endpoint, method: "POST").contains("-X 'POST'"))
    }

    @Test func harCarriesThePostData() throws {
        let entry = NetworkEntry(sequence: 1, category: .bidRequest, trigger: "bid request", source: "client", template: endpoint, url: endpoint,
                                 method: "POST", state: .completed(status: 200), requestHeaders: ["content-type": "application/json; charset=utf-8"],
                                 delivery: .network, requestBodyBytes: bidRequestJSON.utf8.count)
        let data = try HARExporter.data(entries: [entry], requestBodies: [entry.id: Data(bidRequestJSON.utf8)], creatorVersion: "1.0.0")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try #require(((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first?["request"] as? [String: Any])
        let postData = try #require(request["postData"] as? [String: Any])
        #expect(postData["text"] as? String == bidRequestJSON)
        #expect(postData["mimeType"] as? String == "application/json; charset=utf-8")
        #expect(request["bodySize"] as? Int == bidRequestJSON.utf8.count)
        #expect(((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])?.first.flatMap { ($0["_ccinn"] as? [String: Any])?["category"] as? String }
            == "bidRequest")
    }

    @Test func aGETHasNoPostData() throws {
        let entry = NetworkEntry(sequence: 1, category: .content, trigger: "t", source: "s", template: endpoint, url: endpoint, state: .simulated)
        let text = String(decoding: try HARExporter.data(entries: [entry], creatorVersion: "1.0.0"), as: UTF8.self)
        #expect(!text.contains("postData"))
    }
}
