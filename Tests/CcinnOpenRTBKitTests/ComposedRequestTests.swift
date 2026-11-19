import Foundation
import os
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
        try await waitUntilOnTheWire(transport)
        monitor.mode = .simulated
        monitor.cancelInFlightTrackers(reason: "a new render started")

        #expect(try await sending.value.status == 200)
    }

    @Test func goingOfflineCancelsIt() async throws {
        let transport = FakeTransport()
        transport.respond(endpoint, body: bidResponseJSON, delay: .seconds(5))
        let monitor = makeMonitor(transport: transport)

        let sending = Task { try await monitor.send(composed(), userAgent: deviceUA) }
        try await waitUntilOnTheWire(transport)
        monitor.offline = true

        await #expect(throws: NetworkMonitorError.cancelled(NetworkMonitor.offlineCancellation)) { try await sending.value }
        #expect(monitor.liveEntries.first?.isFailure == true)
    }

    @Test func theCallerCanCancelIt() async throws {
        let transport = FakeTransport()
        transport.respond(endpoint, body: bidResponseJSON, delay: .seconds(5))
        let monitor = makeMonitor(transport: transport)

        let sending = Task { try await monitor.send(composed(), userAgent: deviceUA) }
        try await waitUntilOnTheWire(transport)
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

    /// A redirect to another origin (host, scheme or port) is shown, not followed: nothing the user typed — custom
    /// credentials such as `X-Api-Key`, the request's personal data — goes anywhere they did not enter, and https is never
    /// downgraded.
    @Test(arguments: [(307, "https://other.example/auction"), (308, "http://ssp.example/openrtb2/auction"),
                      (301, "https://ssp.example:8443/openrtb2/auction")])
    func aRedirectToAnotherOriginIsShownNotFollowed(status: Int, location: String) async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: location, status: status)
        transport.respond(location, body: bidResponseJSON)
        let monitor = makeMonitor(transport: transport)

        let response = try await monitor.send(composed(headers: ["Content-Type": "application/json", "X-Api-Key": "secret"]), userAgent: deviceUA)

        #expect(response.status == status)
        #expect(HTTPHeaders.value("Location", in: response.headers) == location)
        #expect(transport.requests.count == 1)
        #expect(response.responseEntryID == response.entryID)
        let entry = try #require(monitor.entry(id: response.entryID))
        #expect(entry.state == .completed(status: status))
        #expect(entry.note?.contains("not followed") == true)
        #expect(monitor.liveEntries.count == 1)
    }

    /// The rule itself, for any load that does cross origins: credentials stay behind.
    @Test func theRedirectRuleDropsCredentialsAcrossOrigins() throws {
        let hop = RedirectRule.Hop(method: "POST", body: Data("x".utf8),
                                   headers: ["authorization": "Bearer t", "Cookie": "s=1", "Proxy-Authorization": "Basic x", "X-Keep": "1"])
        let origin = try #require(URL(string: "https://a.example/p"))
        let crossed = RedirectRule.next(after: hop, status: 307, from: origin, to: try #require(URL(string: "https://b.example/p")))
        #expect(crossed.headers == ["X-Keep": "1"])
        #expect(crossed.body == hop.body)
        let same = RedirectRule.next(after: hop, status: 307, from: origin, to: try #require(URL(string: "https://A.example:443/q")))
        #expect(same.headers == hop.headers)
    }

    /// POST /auction → 303 → GET /auction is a different request, not a loop.
    @Test func seeOtherToTheSameURLIsNotALoop() async throws {
        let transport = MethodRoutingTransport { request in
            request.method == "POST" ? HTTPResponse(status: 303, headers: ["Location": endpoint])
                : HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(bidResponseJSON.utf8))
        }
        let monitor = makeMonitor(transport: transport)

        let response = try await monitor.send(composed(), userAgent: deviceUA)

        #expect(response.status == 200)
        #expect(transport.methods == ["POST", "GET"])
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

/// Waits (bounded only against a hang: CI runners are slow) until the transport has the request: from then on it is in
/// flight, which a fixed sleep cannot promise.
@MainActor
private func waitUntilOnTheWire(_ transport: FakeTransport) async throws {
    for _ in 0..<2_000 where transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(transport.requests.count == 1, "the request never reached the transport")
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
        #expect(command == #"curl --globoff -H 'Content-Type: application/json' --data-raw '{"# + "\n" + #"  "site": "it'\''s""# + "\n"
            + #"}' --url 'https://ssp.example/openrtb2/auction'"#)
    }

    /// `--data-binary '@file'` would make curl read a local file and upload it: the body is never read as a file name.
    @Test func aBodyStartingWithAnAtSignIsSentAsText() {
        let command = CurlCommand.make(url: endpoint, method: "POST", body: Data("@/Users/me/.ssh/id_rsa".utf8))
        #expect(command.contains("--data-raw '@/Users/me/.ssh/id_rsa'"))
        #expect(!command.contains("--data-binary"))
        #expect(!command.contains(" -d "))
    }

    /// A raw control character cannot be in JSON text and must not reach a terminal: written as its JSON escape.
    @Test func curlEscapesControlCharactersOtherThanWhitespace() {
        let command = CurlCommand.make(url: endpoint, method: "POST", body: Data("{\"a\":\"x\u{1B}[31m\u{0}\"}\t".utf8))
        #expect(command.contains(#"--data-raw '{"a":"x\u001B[31m\u0000"}"# + "\t'"))
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

/// Answers by method, records the methods it saw.
final class MethodRoutingTransport: HTTPTransport {
    private let answer: @Sendable (HTTPRequest) -> HTTPResponse
    private let seen = OSAllocatedUnfairLock(initialState: [String]())

    init(_ answer: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.answer = answer
    }

    var methods: [String] { seen.withLock { $0 } }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        seen.withLock { $0.append(request.method) }
        return answer(request)
    }
}

/// The Client's redirect setting (bid-client 1.2): follow all, within the origin (the default), or none — and the chain
/// of every request sent, so a redirect can be inspected hop by hop.
@MainActor
@Suite("Network monitor: composed redirects")
struct ComposedRedirectPolicyTests {
    private func send(_ monitor: NetworkMonitor, _ policy: RedirectPolicy, url: String = endpoint,
                      headers: [String: String] = ["Content-Type": "application/json"]) async throws -> ComposedResponse {
        var request = composed(url, headers: headers)
        request.redirects = policy
        return try await monitor.send(request, userAgent: deviceUA)
    }

    @Test func withinTheOriginIsTheDefault() {
        #expect(ComposedRequest(url: endpoint).redirects == .sameOrigin)
        #expect(RedirectPolicy.allCases == [.all, .sameOrigin, .none])
    }

    @Test func aDirectAnswerIsAChainOfOne() async throws {
        let transport = FakeTransport()
        transport.respond(endpoint, body: bidResponseJSON)
        let monitor = makeMonitor(transport: transport)

        let response = try await send(monitor, .all)

        #expect(response.chain.count == 1)
        #expect(response.chain.first?.method == "POST")
        #expect(response.chain.first?.status == 200)
        #expect(response.chain.first?.wasSent == true)
        #expect(response.chain.first?.bodyBytes == bidRequestJSON.utf8.count)
        #expect(response.redirectStop == nil)
    }

    @Test func dontFollowAnswersWithTheFirstRedirect() async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "/v2/auction", status: 302)
        let monitor = makeMonitor(transport: transport)

        let response = try await send(monitor, .none)

        #expect(response.status == 302)
        #expect(transport.requests.count == 1)
        #expect(response.chain.map(\.status) == [302])
        #expect(response.chain.first?.location == "/v2/auction")
        #expect(response.redirectStop == .notFollowed(.none, location: "/v2/auction"))
        #expect(response.redirectStop?.canBeFollowed == true)
    }

    /// Follow all: like `curl -L`, across origins; the standard credentials stay behind and the hop says so, other headers
    /// and (on 307 / 308) the body go along.
    @Test func followAllCrossesOriginsWithoutTheStandardCredentials() async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "https://other.example/auction", status: 307)
        transport.respond("https://other.example/auction", body: bidResponseJSON)
        let monitor = makeMonitor(transport: transport)

        let response = try await send(monitor, .all, headers: ["Content-Type": "application/json", "Authorization": "Bearer t", "Cookie": "s=1",
                                                                "X-Api-Key": "k"])

        #expect(response.status == 200)
        #expect(response.url.absoluteString == "https://other.example/auction")
        let hop = try #require(transport.requests.last)
        #expect(transport.requests.count == 2)
        #expect(hop.method == "POST")
        #expect(hop.body == Data(bidRequestJSON.utf8))
        #expect(headerValues("Authorization", in: hop.headers).isEmpty)
        #expect(headerValues("Cookie", in: hop.headers).isEmpty)
        #expect(hop.headers["X-Api-Key"] == "k")
        #expect(response.chain.map(\.url) == [endpoint, "https://other.example/auction"])
        #expect(response.chain.map(\.status) == [307, 200])
        #expect(response.chain.first?.location == "https://other.example/auction")
        let note = try #require(response.chain.last?.note)
        #expect(note.contains("Authorization") && note.contains("Cookie"))
        #expect(!note.contains("X-Api-Key"))
        #expect(response.chain.last?.bodyBytes == bidRequestJSON.utf8.count)
        #expect(response.redirectStop == nil)
    }

    /// A downgrade to http is followed when asked to, and flagged: what follows is sent unencrypted.
    @Test func followAllFlagsADowngradeAndAMethodChange() async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "http://ssp.example/openrtb2/auction", status: 301)
        transport.respond("http://ssp.example/openrtb2/auction", body: "{}")
        let monitor = makeMonitor(transport: transport)

        let response = try await send(monitor, .all)

        #expect(transport.requests.map(\.method) == ["POST", "GET"])
        let note = try #require(response.chain.last?.note)
        #expect(note.contains("unencrypted"))
        #expect(note.contains("GET"))
        #expect(response.chain.last?.bodyBytes == nil)
    }

    /// A loop is a result to inspect, not just an error: the last 3xx, the chain, and why it stopped.
    @Test func aLoopEndsTheChainWithItsReason() async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "https://ssp.example/b", status: 307)
        transport.redirect("https://ssp.example/b", to: endpoint, status: 307)
        let monitor = makeMonitor(transport: transport)

        let response = try await send(monitor, .all)

        #expect(response.status == 307)
        #expect(transport.requests.count == 2)
        #expect(response.redirectStop == .loop(endpoint))
        #expect(response.redirectStop?.canBeFollowed == false)
        #expect(response.chain.map(\.wasSent) == [true, true, false])
        #expect(response.chain.last?.url == endpoint)
        #expect(response.chain.last?.failure != nil)
    }

    @Test func tooManyRedirectsEndTheChainWithItsReason() async throws {
        let transport = FakeTransport()
        let base = "https://ssp.example/r"
        transport.redirect(endpoint, to: base + "1", status: 307)
        for index in 1...NetworkMonitor.maxRedirects + 1 { transport.redirect(base + "\(index)", to: base + "\(index + 1)", status: 307) }
        let monitor = makeMonitor(transport: transport)

        let response = try await send(monitor, .all)

        #expect(transport.requests.count == NetworkMonitor.maxRedirects + 1)
        #expect(response.status == 307)
        #expect(response.redirectStop == .tooManyRedirects(limit: NetworkMonitor.maxRedirects))
        #expect(response.chain.count == NetworkMonitor.maxRedirects + 2)
        #expect(response.chain.filter(\.wasSent).count == NetworkMonitor.maxRedirects + 1)
    }

    /// Within the origin (the default): followed while it stays, the 3xx out of it is the answer, with the reason.
    @Test func withinTheOriginStopsAtTheBorder() async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "/v2", status: 307)
        transport.redirect("https://ssp.example/v2", to: "https://other.example/v3", status: 307)
        let monitor = makeMonitor(transport: transport)

        let response = try await send(monitor, .sameOrigin)

        #expect(transport.requests.count == 2)
        #expect(response.status == 307)
        #expect(response.chain.map(\.status) == [307, 307])
        #expect(response.redirectStop == .notFollowed(.sameOrigin, location: "https://other.example/v3"))
    }

    /// A target that is not http(s) is a dead end whatever the setting — never "another origin" that Follow all could fix.
    @Test(arguments: [RedirectPolicy.sameOrigin, .all])
    func aNonHTTPTargetIsAStructuralStop(policy: RedirectPolicy) async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "itms-apps://apps.apple.com/app/id1", status: 302)
        let monitor = makeMonitor(transport: transport)

        let response = try await send(monitor, policy)

        #expect(response.redirectStop == .unsupportedScheme("itms-apps://apps.apple.com/app/id1"))
        #expect(response.redirectStop?.canBeFollowed == false)
        #expect(transport.requests.count == 1)
    }

    /// Credentials left behind stay behind, even when the chain comes back to the first origin (any header-name case).
    @Test func credentialsDoNotComeBackWhenTheChainReturns() async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "https://other.example/hop", status: 307)
        transport.redirect("https://other.example/hop", to: "https://ssp.example/final", status: 307)
        transport.respond("https://ssp.example/final", body: "{}")
        let monitor = makeMonitor(transport: transport)

        _ = try await send(monitor, .all, headers: ["content-type": "application/json", "authorization": "Bearer t", "cookie": "s=1"])

        #expect(transport.requests.count == 3)
        #expect(transport.requests.dropFirst().allSatisfy { headerValues("Authorization", in: $0.headers).isEmpty && headerValues("Cookie", in: $0.headers).isEmpty })
    }

    /// A body cut at the limit is never an answer, on a redirect that ends the chain either.
    @Test func aTruncatedRedirectBodyFails() async throws {
        let transport = FakeTransport()
        transport.respond(endpoint, status: 302, headers: ["Location": "https://other.example/"], body: String(repeating: "x", count: 64))
        let monitor = makeMonitor(transport: transport)
        monitor.composedBodyLimit = 16

        await #expect(throws: NetworkMonitorError.tooLarge(limit: 16)) { try await send(monitor, .sameOrigin) }
    }

    /// Going Offline in the middle of a followed chain stops it before the next hop.
    @Test func goingOfflineMidChainStopsTheNextHop() async throws {
        let transport = FakeTransport()
        transport.redirect(endpoint, to: "https://other.example/hop", status: 307)
        transport.respond("https://other.example/hop", body: "{}", delay: .seconds(5))
        let monitor = makeMonitor(transport: transport)

        let sending = Task { try await send(monitor, .all) }
        for _ in 0..<2_000 where transport.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        monitor.offline = true

        await #expect(throws: NetworkMonitorError.cancelled(NetworkMonitor.offlineCancellation)) { try await sending.value }
    }
}


/// The redirect rework must leave every other load as it was.
@MainActor
@Suite("Network monitor: redirects of other loads")
struct OtherLoadRedirectTests {
    @Test func contentLoopsAndLongChainsStillThrow() async throws {
        let transport = FakeTransport()
        transport.redirect("https://cdn.example/a", to: "https://cdn.example/b")
        transport.redirect("https://cdn.example/b", to: "https://cdn.example/a")
        let monitor = makeMonitor(transport: transport)
        await #expect(throws: NetworkMonitorError.redirectLoop("https://cdn.example/a")) {
            _ = try await monitor.fetchContent("https://cdn.example/a", trigger: "t", source: "s", parentID: nil, userAgent: deviceUA)
        }
    }

    /// Hop notes about method, body, credentials and downgrades are for composed requests; a tracker's hop keeps its own.
    @Test func trackerHopsKeepTheirNotes() async throws {
        let transport = FakeTransport()
        transport.redirect("https://dsp.example/win", to: "http://cdn.example/px", status: 302)
        transport.respond("http://cdn.example/px", body: "")
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .real

        monitor.dispatch(tracker(.win, "https://dsp.example/win"), userAgent: deviceUA)
        await monitor.waitUntilIdle()

        #expect(monitor.liveEntries.last?.note == "Redirect hop 1")
    }

    @Test func curlFollowsRedirectsWhenAsked() {
        #expect(CurlCommand.make(url: endpoint, followsRedirects: true).contains("--location --max-redirs 10"))
        #expect(!CurlCommand.make(url: endpoint).contains("--location"))
    }
}

/// Cookie-sync runs (1.3): a composed request with a cookie session sends the jar's cookies on every hop and stores the
/// `Set-Cookie`s it receives, as the session's browser would; each hop records what was sent, withheld, stored and
/// rejected.
@MainActor
@Suite("Network monitor: cookie sessions")
struct CookieSessionMonitorTests {
    private let syncStart = "https://ssp.example/usersync?bidder=dsp"
    private let dspPixel = "https://sync.dsp.example/pixel?redir=https%3A%2F%2Fssp.example%2Fsetuid%3Fbidder%3Ddsp%26uid%3D%24UID"
    private let setuid = "https://ssp.example/setuid?bidder=dsp&uid=abc123"

    private func session(_ policy: CookiePolicy, publisher: String = "https://news.example") -> CookieSession {
        CookieSession(context: CookieContext(topLevelSite: CookieSite(url: URL(string: publisher)!)!, policy: policy))
    }

    private func syncTransport() -> FakeTransport {
        let transport = FakeTransport()
        transport.respond(syncStart, status: 302, headers: ["Location": dspPixel, "Set-Cookie": "ssp_sid=s1; Secure; SameSite=None; Path=/"])
        transport.respond(dspPixel, status: 302, headers: ["Location": setuid,
                                                           "Set-Cookie": "uid=abc123; Domain=dsp.example; Max-Age=3600; Secure; SameSite=None, lax=1; Secure"])
        transport.respond(setuid, status: 200, headers: ["Content-Type": "image/gif", "Set-Cookie": "uids=eyJkc3AiOiJhYmMxMjMifQ; Secure; SameSite=None; Path=/"])
        return transport
    }

    private func run(_ monitor: NetworkMonitor, _ cookies: CookieSession) async throws -> ComposedResponse {
        try await monitor.send(ComposedRequest(url: syncStart, method: "GET", redirects: .all, purpose: .userSync, cookies: cookies), userAgent: deviceUA)
    }

    @Test func aSyncChainStoresAndSendsCookiesHopByHop() async throws {
        let transport = syncTransport()
        let monitor = makeMonitor(transport: transport)
        let cookies = session(.allowThirdParty)

        let first = try await run(monitor, cookies)

        #expect(first.status == 200)
        #expect(first.chain.count == 3)
        #expect(Set(cookies.jar.cookies.map(\.name)) == ["ssp_sid", "uid", "uids"])
        let pixelHop = first.chain[1]
        #expect(pixelHop.cookies?.decisions.contains { if case .stored(let cookie) = $0 { cookie.name == "uid" } else { false } } == true)
        #expect(pixelHop.cookies?.decisions.contains(.rejected(name: "lax", reason: .sameSiteCrossSite(.lax))) == true)
        #expect(monitor.entry(id: first.entryID)?.category == .userSync)
        // Within the run: the SSP's cookie from hop 1 comes back on hop 3 (setuid, the same SSP); the DSP had none yet.
        #expect(transport.requests.map { headerValues("Cookie", in: $0.headers).first ?? "" } == ["", "", "ssp_sid=s1"])

        // Run again: the cookies the chain set are sent back where they belong.
        let second = try await run(monitor, cookies)
        let sent = transport.requests.suffix(3).map { headerValues("Cookie", in: $0.headers).first ?? "" }
        #expect(sent == ["ssp_sid=s1; uids=eyJkc3AiOiJhYmMxMjMifQ", "uid=abc123", "ssp_sid=s1; uids=eyJkc3AiOiJhYmMxMjMifQ"])
        #expect(second.chain[1].cookies?.sent.map(\.name) == ["uid"])
    }

    /// The iPhone's browser (WebKit) blocks third-party cookies: the same chain stores nothing and sends nothing.
    @Test func webKitBlocksTheThirdPartyChain() async throws {
        let transport = syncTransport()
        let monitor = makeMonitor(transport: transport)
        let cookies = session(.blockThirdParty)

        let response = try await run(monitor, cookies)
        _ = try await run(monitor, cookies)

        #expect(cookies.jar.cookies.isEmpty)
        #expect(response.chain.allSatisfy { hop in
            hop.cookies?.decisions.allSatisfy { if case .rejected(_, .thirdPartyBlocked) = $0 { true } else { false } } ?? true
        })
        #expect(transport.requests.allSatisfy { headerValues("Cookie", in: $0.headers).isEmpty })
    }

    /// A user-typed Cookie header never mixes with the jar's: the jar decides.
    @Test func theJarReplacesAHandWrittenCookieHeader() async throws {
        let transport = syncTransport()
        let monitor = makeMonitor(transport: transport)
        var request = ComposedRequest(url: syncStart, method: "GET", headers: ["cookie": "forged=1"], redirects: .all, purpose: .userSync,
                                      cookies: session(.allowThirdParty))
        request.trigger = "user sync"
        _ = try await monitor.send(request, userAgent: deviceUA)
        #expect(headerValues("Cookie", in: transport.requests[0].headers).isEmpty)
        #expect(!transport.requests.contains { headerValues("Cookie", in: $0.headers).contains { $0.contains("forged") } })
    }

    @Test func aUserSyncIsNoTrackerAndOfflineSendsNothing() async throws {
        #expect(!TrackerCategory.userSync.isTracker)
        #expect(DispatchPolicy.permit(for: .userSync, isScript: false, mode: .simulated) != nil)
        #expect(DispatchPolicy.permit(for: .userSync, isScript: false, mode: .real, offline: true) == nil)
        let monitor = makeMonitor(transport: FailingTransport())
        monitor.offline = true
        await #expect(throws: NetworkMonitorError.self) { try await run(monitor, session(.allowThirdParty)) }
        #expect(monitor.liveEntries.map(\.category) == [.userSync])
    }
}

@Suite("Cookies on the wire", .serialized)
struct CookieWireTests {
    /// The real transport sends a hand-set Cookie header (cookie handling is off) and reports every Set-Cookie line,
    /// joined, which `SetCookieLines.split` takes apart.
    @MainActor
    @Test func cookiesTravelBothWays() async throws {
        let server = try LoopbackHTTPServer { _ in
            LoopbackHTTPServer.Response(status: 200, headers: ["Set-Cookie": "a=1; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT\r\nSet-Cookie: b=2; Path=/"])
        }
        let port = try await server.start()
        defer { server.stop() }
        let monitor = NetworkMonitor(transport: URLSessionTransport(), publishInterval: .zero)
        let cookies = CookieSession(context: CookieContext(topLevelSite: CookieSite(url: URL(string: "http://127.0.0.1:\(port)")!)!, policy: .allowThirdParty))
        let url = "http://127.0.0.1:\(port)/sync"

        _ = try await monitor.send(ComposedRequest(url: url, method: "GET", purpose: .userSync, cookies: cookies), userAgent: deviceUA)
        _ = try await monitor.send(ComposedRequest(url: url, method: "GET", purpose: .userSync, cookies: cookies), userAgent: deviceUA)

        #expect(Set(cookies.jar.cookies.map(\.name)) == ["a", "b"])
        #expect(server.requests.first?.header("Cookie") == nil)
        #expect(server.requests.last?.header("Cookie") == "a=1; b=2")
    }
}

@Suite("Redirect rule: Referer")
struct RedirectRefererTests {
    /// strict-origin-when-cross-origin: no Referer on a downgrade to http.
    @Test func aDowngradeDropsTheReferer() throws {
        let hop = RedirectRule.Hop(method: "GET", body: nil, headers: ["Referer": "https://news.example/", "Accept": "image/*"])
        let next = RedirectRule.next(after: hop, status: 302, from: try #require(URL(string: "https://ssp.example/a")),
                                     to: try #require(URL(string: "http://ssp.example/b")))
        #expect(next.headers == ["Accept": "image/*"])
        let same = RedirectRule.next(after: hop, status: 302, from: try #require(URL(string: "https://ssp.example/a")),
                                     to: try #require(URL(string: "https://dsp.example/b")))
        #expect(same.headers["Referer"] == "https://news.example/")
    }
}
