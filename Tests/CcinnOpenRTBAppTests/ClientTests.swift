import CcinnOpenRTBKit
import Foundation
import os
import RTBKit
import Testing
@testable import CcinnOpenRTB

private let endpoint = "https://ssp.example/openrtb2/auction"
private let rewardedVideoRequest = #"{"id":"req-1","imp":[{"id":"1","video":{"w":640,"h":360,"mimes":["video/mp4"]},"instl":1,"rwdd":1}]}"#
private let inlineVAST = #"<VAST version=\"4.2\"><Ad id=\"a\"><InLine><AdSystem>DSP</AdSystem><AdTitle>T</AdTitle><Impression><![CDATA[https://imp.dsp.example/i]]></Impression><Creatives><Creative><Linear><Duration>00:00:15</Duration><MediaFiles><MediaFile delivery=\"progressive\" type=\"video/mp4\" width=\"1280\" height=\"720\"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile></MediaFiles></Linear></Creative></Creatives></InLine></Ad></VAST>"#
private let videoResponse = #"{"id":"req-1","seatbid":[{"seat":"dsp","bid":[{"id":"b1","impid":"1","price":2.5,"mtype":2,"adm":""# + inlineVAST
    + #"","burl":"https://bill.dsp.example/b?p=${AUCTION_PRICE}"}]}]}"#

/// Answers by URL; records every request.
final class ScriptedTransport: HTTPTransport {
    struct Answer: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = ""
        var delay: Duration?
    }

    private struct State {
        var answers: [String: Answer] = [:]
        var requests: [HTTPRequest] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var requests: [HTTPRequest] { state.withLockUnchecked { $0.requests } }

    func answer(_ url: String, _ answer: Answer) { state.withLockUnchecked { $0.answers[url] = answer } }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        let answer = state.withLockUnchecked { state -> Answer? in
            state.requests.append(request)
            return state.answers[request.url.absoluteString]
        }
        guard let answer else { throw URLError(.cannotFindHost) }
        if let delay = answer.delay { try await Task.sleep(for: delay) }
        return HTTPResponse(status: answer.status, headers: answer.headers, body: Data(answer.body.utf8))
    }
}

/// Records what the Client hands to the simulator.
@MainActor
final class RecordingSimulatorTarget: ClientSimulatorTarget {
    struct Load: Equatable {
        var request: String
        var response: String
        var deviceID: String?
        var render: Bool
    }

    let monitor: NetworkMonitor
    var device: DeviceProfile = DeviceCatalog.defaultDevice
    var mode: TrackingMode { monitor.mode }
    private(set) var loads: [Load] = []

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
    }

    func loadExchange(request: String, response: String, device: DeviceProfile?, render: Bool) async {
        loads.append(Load(request: request, response: response, deviceID: device?.id, render: render))
    }
}

/// A fresh directory under the temporary directory, removed by `cleanUp()`.
struct TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-client-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("Requests", isDirectory: true)

    func cleanUp() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    func permissions(_ path: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue
    }
}

private func request(_ url: String = endpoint, method: ClientMethod = .post, body: String = rewardedVideoRequest,
                     headers: [ClientHeader] = ClientRequest.defaultHeaders()) -> ClientRequest {
    ClientRequest(method: method, url: url, headers: headers, body: body)
}

// MARK: - Request

@Suite("Client: request")
struct ClientRequestTests {
    @Test func newRequestsPostJSONWithTheOpenRTBVersionHeader() {
        let fresh = ClientRequest()
        #expect(fresh.method == .post)
        #expect(fresh.url.isEmpty)
        #expect(fresh.headers.map { "\($0.name): \($0.value)" } == ["Content-Type: application/json", "x-openrtb-version: 2.6"])
        #expect(fresh.headers.allSatisfy { $0.isEnabled })
        #expect(fresh.problems() == [.missingURL])
    }

    @Test func aValidPOSTComposesExactlyWhatIsSent() throws {
        var draft = request("  \(endpoint)  ")
        draft.headers.append(ClientHeader(name: "X-Disabled", value: "1", isEnabled: false))
        draft.headers.append(ClientHeader(name: " ", value: " "))
        draft.headers.append(ClientHeader(name: " Authorization ", value: " Bearer t "))
        let composed = try draft.composed()
        #expect(composed.url == endpoint)
        #expect(composed.wireMethod == "POST")
        #expect(composed.headers == ["Content-Type": "application/json", "x-openrtb-version": "2.6", "Authorization": "Bearer t"])
        #expect(composed.body == Data(rewardedVideoRequest.utf8))
        #expect(composed.trigger == "bid request")
        #expect(composed.source == "client")
    }

    @Test func aGETSendsNoBody() throws {
        #expect(try request(method: .get).composed().wireBody == nil)
    }

    @Test(arguments: ["ftp://ssp.example/bid", "ssp.example/bid", "https://", "http:///path", "javascript:alert(1)", "data:,{}"])
    func onlyHTTPURLsWithAHostAreSent(url: String) {
        let problems = request(url).problems()
        #expect(problems == [.invalidURL], "\(url): \(problems)")
        #expect(throws: ClientRequest.Invalid.self) { try request(url).composed() }
    }

    @Test func headerNamesMustBeTokensAndValuesSingleLines() {
        let draft = request(headers: [ClientHeader(name: "Bad Name", value: "1"), ClientHeader(name: "X:Y", value: "1"),
                                      ClientHeader(name: "", value: "orphan"), ClientHeader(name: "X-Split", value: "a\r\nInjected: 1"),
                                      ClientHeader(name: "X-Null", value: "a\u{0}b"), ClientHeader(name: "X-CR", value: "a\rb"),
                                      ClientHeader(name: "X-LF", value: "a\nb")])
        #expect(draft.problems() == [.invalidHeaderName("Bad Name"), .invalidHeaderName("X:Y"), .invalidHeaderName(""),
                                     .invalidHeaderValue("X-Split"), .invalidHeaderValue("X-Null"), .invalidHeaderValue("X-CR"),
                                     .invalidHeaderValue("X-LF")])
    }

    /// Two enabled headers of one name (any case) cannot both be sent as written: refused rather than one silently lost.
    @Test func duplicateEnabledHeadersAreRefused() {
        let duplicate = request(headers: [ClientHeader(name: "Content-Type", value: "application/json"),
                                          ClientHeader(name: "content-type", value: "text/plain")])
        #expect(duplicate.problems() == [.duplicateHeader("content-type")])
        let disabled = request(headers: [ClientHeader(name: "Content-Type", value: "application/json"),
                                         ClientHeader(name: "content-type", value: "text/plain", isEnabled: false)])
        #expect(disabled.problems().isEmpty)
    }

    @Test func everyProblemHasAMessage() {
        let problems: [ClientRequest.Problem] = [.missingURL, .invalidURL, .invalidHeaderName("A B"), .invalidHeaderValue("X"), .duplicateHeader("x")]
        #expect(problems.allSatisfy { !$0.message.isEmpty })
        #expect(ClientRequest.Invalid(problems: problems).message.contains("A B"))
    }

    @Test func aBodyThatIsNotJSONIsWarnedAboutNotRefused() throws {
        #expect(request(body: "{\"id\":").jsonWarning != nil)
        #expect(request(body: rewardedVideoRequest).jsonWarning == nil)
        #expect(request(body: "  ").jsonWarning == nil)
        #expect(request(method: .get, body: "not json").jsonWarning == nil)
        #expect(throws: Never.self) { try request(body: "{\"id\":").composed() }
    }

    @Test func requestsRoundTripThroughCodable() throws {
        let draft = request(headers: ClientRequest.defaultHeaders() + [ClientHeader(name: "X-Off", value: "1", isEnabled: false)])
        #expect(try JSONDecoder().decode(ClientRequest.self, from: JSONEncoder().encode(draft)) == draft)
    }
}

// MARK: - Response

@Suite("Client: response")
struct ClientResponseTests {
    private func composed(status: Int, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) -> ComposedResponse {
        ComposedResponse(status: status, headers: headers, body: body, url: URL(string: endpoint)!, entryID: UUID(), responseEntryID: UUID(),
                         duration: 0.1234, timings: nil)
    }

    @Test func keepsWhatTheServerSent() {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let response = ClientResponse(composed(status: 200, body: Data(videoResponse.utf8)), receivedAt: receivedAt)
        #expect(response.status == 200)
        #expect(response.body == videoResponse)
        #expect(response.bodyBytes == videoResponse.utf8.count)
        #expect(abs(response.durationMilliseconds - 123.4) < 0.001)
        #expect(response.receivedAt == receivedAt)
        #expect(response.url == endpoint)
        #expect(response.mimeType == "application/json")
        #expect(response.carriesAResponseToRender)
    }

    @Test func theCharsetIsHonoured() {
        let latin = ClientResponse(composed(status: 200, body: "{\"t\":\"Caf\u{E9}\"}".data(using: .isoLatin1)!,
                                            headers: ["Content-Type": "application/json; charset=iso-8859-1"]), receivedAt: Date())
        #expect(latin.body == "{\"t\":\"Caf\u{E9}\"}")
    }

    @Test(arguments: [(204, ""), (200, "  \n"), (400, "{\"error\":1}"), (500, "{}"), (302, "")])
    func onlyA2xxWithABodyGoesToTheSimulator(status: Int, body: String) {
        #expect(!ClientResponse(composed(status: status, body: Data(body.utf8)), receivedAt: Date()).carriesAResponseToRender)
    }
}

// MARK: - Store

@Suite("Saved requests: store", .serialized)
struct SavedRequestStoreTests {
    private func saved(_ name: String, updatedAt: TimeInterval = 1_800_000_000, id: UUID = UUID()) -> SavedRequest {
        let date = Date(timeIntervalSince1970: updatedAt)
        let response = ClientResponse(status: 200, headers: ["Content-Type": "application/json"], body: videoResponse,
                                      bodyBytes: videoResponse.utf8.count, durationMilliseconds: 42, receivedAt: date, url: endpoint)
        return SavedRequest(id: id, name: name, createdAt: date, updatedAt: date, request: request(),
                            exchange: ClientExchange(requestBody: rewardedVideoRequest, response: response, deviceID: "iphone-18-pro"))
    }

    @Test func savedRequestsRoundTripWithPrivatePermissions() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let store = SavedRequestStore(directory: directory.url)
        let item = saved("Rewarded video")

        try await store.write(item)
        let snapshot = try await store.loadAll()

        #expect(snapshot.requests == [item])
        #expect(snapshot.unreadable.isEmpty)
        let file = directory.url.appendingPathComponent("\(item.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(directory.permissions(directory.url) == 0o700)
        #expect(directory.permissions(file) == 0o600)
    }

    @Test func aMissingDirectoryIsAnEmptyLibrary() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let snapshot = try await SavedRequestStore(directory: directory.url).loadAll()
        #expect(snapshot.requests.isEmpty)
        #expect(snapshot.unreadable.isEmpty)
    }

    @Test func deletingRemovesTheFileAndAMissingOneIsFine() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let store = SavedRequestStore(directory: directory.url)
        let item = saved("A")
        try await store.write(item)

        try await store.delete(id: item.id)
        try await store.delete(id: item.id)

        #expect(try await store.loadAll().requests.isEmpty)
    }

    /// A damaged, foreign or oversized file is skipped and reported, never fatal; other files are not ours to read.
    @Test func unreadableFilesAreSkippedAndCounted() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let store = SavedRequestStore(directory: directory.url, maxFileBytes: 64 * 1024)
        let good = saved("Good")
        try await store.write(good)
        try Data("{not json".utf8).write(to: directory.url.appendingPathComponent("broken.json"))
        try Data(#"{"name":"no id"}"#.utf8).write(to: directory.url.appendingPathComponent("foreign.json"))
        try Data(repeating: 0x20, count: 65 * 1024).write(to: directory.url.appendingPathComponent("huge.json"))
        try Data("notes".utf8).write(to: directory.url.appendingPathComponent("notes.txt"))

        let snapshot = try await store.loadAll()

        #expect(snapshot.requests == [good])
        #expect(snapshot.unreadable.sorted() == ["broken.json", "foreign.json", "huge.json"])
    }

    /// Two files claiming one id (a copied file): the most recently updated wins, so the list never shows one id twice.
    @Test func oneRequestPerID() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let store = SavedRequestStore(directory: directory.url)
        let id = UUID()
        let older = saved("Older", updatedAt: 1_800_000_000, id: id)
        let newer = saved("Newer", updatedAt: 1_800_000_100, id: id)
        try await store.write(older)
        try FileManager.default.copyItem(at: directory.url.appendingPathComponent("\(id.uuidString).json"),
                                         to: directory.url.appendingPathComponent("copy.json"))
        try await store.write(newer)

        #expect(try await store.loadAll().requests == [newer])
    }
}

// MARK: - Library

@MainActor
@Suite("Saved requests: library", .serialized)
struct SavedRequestLibraryTests {
    private func item(_ name: String, at seconds: TimeInterval) -> SavedRequest {
        let date = Date(timeIntervalSince1970: seconds)
        return SavedRequest(id: UUID(), name: name, createdAt: date, updatedAt: date, request: request(), exchange: nil)
    }

    @Test func savesListsNewestFirstAndPersists() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))
        let first = item("First", at: 100)
        let second = item("Second", at: 200)

        #expect(await library.save(first))
        #expect(await library.save(second))
        var renamed = first
        renamed.name = "First, renamed"
        renamed.updatedAt = Date(timeIntervalSince1970: 300)
        #expect(await library.save(renamed))

        #expect(library.requests.map(\.name) == ["First, renamed", "Second"])
        let reopened = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))
        await reopened.loadIfNeeded()
        #expect(reopened.requests == library.requests)

        await library.delete(second.id)
        #expect(library.requests.map(\.name) == ["First, renamed"])
        let again = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))
        await again.loadIfNeeded()
        #expect(again.requests.map(\.id) == [first.id])
    }

    @Test func aFailedWriteKeepsTheListAndSaysWhy() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        // A file where the directory should be: nothing can be written.
        try FileManager.default.createDirectory(at: directory.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.url)
        let library = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))

        #expect(await library.save(item("Lost", at: 1)) == false)
        #expect(library.requests.isEmpty)
        #expect(library.lastError != nil)
    }

    @Test func duplicatingMakesAnIndependentCopy() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url), now: { Date(timeIntervalSince1970: 500) })
        let original = item("Video", at: 100)
        #expect(await library.save(original))

        let copy = try #require(await library.duplicate(original.id))

        #expect(copy.id != original.id)
        #expect(copy.name == "Video copy")
        #expect(copy.request == original.request)
        #expect(library.requests.map(\.id) == [copy.id, original.id])
    }
}

// MARK: - Model

@MainActor
@Suite("Client: model", .serialized)
struct ClientModelTests {
    @MainActor
    private struct Harness {
        let transport = ScriptedTransport()
        let monitor: NetworkMonitor
        let target: RecordingSimulatorTarget
        let directory = TemporaryDirectory()
        let library: SavedRequestLibrary
        let model: ClientModel

        init() {
            monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
            target = RecordingSimulatorTarget(monitor: monitor)
            library = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))
            model = ClientModel(target: target, library: library, now: { Date(timeIntervalSince1970: 1_800_000_000) })
            model.request = request()
        }
    }

    @Test func aBidIsSentAndShownOnTheDevice() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.transport.answer(endpoint, .init(body: videoResponse))

        await harness.model.send()?.value

        #expect(harness.model.phase == .received)
        let exchange = try #require(harness.model.exchange)
        #expect(exchange.response.status == 200)
        #expect(exchange.response.body == videoResponse)
        #expect(exchange.requestBody == rewardedVideoRequest)
        #expect(exchange.deviceID == "iphone-18-pro")
        #expect(harness.model.exchangeOrigin == .sent)
        #expect(harness.target.loads == [.init(request: rewardedVideoRequest, response: videoResponse, deviceID: "iphone-18-pro", render: true)])
        let sent = try #require(harness.transport.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.body == Data(rewardedVideoRequest.utf8))
        #expect(sent.headers["User-Agent"] == DeviceCatalog.defaultDevice.userAgent)
    }

    /// Real mode never sends without an explicit Render: the editors get the exchange, the device does not render it.
    @Test func realModeLoadsTheEditorsAndWaitsForRender() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.transport.answer(endpoint, .init(body: videoResponse))
        harness.monitor.mode = .real

        await harness.model.send()?.value

        #expect(harness.target.loads.map(\.render) == [false])
        #expect(harness.model.simulatorNote?.contains("Render") == true)
    }

    @Test(arguments: [(204, ""), (400, #"{"error":"bad imp"}"#), (503, "")])
    func noBidOrAnErrorLeavesTheSimulatorAlone(status: Int, body: String) async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.transport.answer(endpoint, .init(status: status, body: body))

        await harness.model.send()?.value

        #expect(harness.model.phase == .received)
        #expect(harness.model.exchange?.response.status == status)
        #expect(harness.model.exchange?.response.body == body)
        #expect(harness.target.loads.isEmpty)
        #expect(harness.model.simulatorNote != nil)
    }

    /// A body that is not JSON is sent as typed, with a note (computed off the main actor).
    @Test func aBodyThatIsNotJSONIsSentWithANote() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.transport.answer(endpoint, .init(status: 400, body: "{}"))
        harness.model.request.body = "{\"id\":"

        await harness.model.send()?.value
        for _ in 0..<100 where harness.model.sendWarning == nil { try await Task.sleep(for: .milliseconds(5)) }

        #expect(harness.transport.requests.first?.body == Data("{\"id\":".utf8))
        #expect(harness.model.sendWarning != nil)
    }

    @Test func offlineSendsNothingAndSaysSo() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.monitor.offline = true

        await harness.model.send()?.value

        guard case let .failed(message) = harness.model.phase else {
            Issue.record("expected a failure, got \(harness.model.phase)")
            return
        }
        #expect(message.contains("Offline"))
        #expect(harness.transport.requests.isEmpty)
        #expect(harness.monitor.liveEntries.map(\.delivery) == [.offline])
    }

    @Test func anInvalidRequestIsNotSent() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.model.request.url = "ssp.example/no-scheme"

        #expect(harness.model.send() == nil)

        #expect(harness.model.canSend == false)
        guard case .failed = harness.model.phase else {
            Issue.record("expected a failure, got \(harness.model.phase)")
            return
        }
        #expect(harness.monitor.liveEntries.isEmpty)
    }

    /// The simulator gets the body that produced the response, not one edited while it was in flight.
    @Test func editsInFlightDoNotChangeWhatIsShown() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.transport.answer(endpoint, .init(body: videoResponse, delay: .milliseconds(80)))

        let sending = harness.model.send()
        #expect(harness.model.phase == .sending)
        harness.model.request.body = "{\"edited\":true}"
        await sending?.value

        #expect(harness.model.exchange?.requestBody == rewardedVideoRequest)
        #expect(harness.target.loads.first?.request == rewardedVideoRequest)
    }

    @Test func cancellingDropsTheLateResponse() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.transport.answer(endpoint, .init(body: videoResponse, delay: .milliseconds(200)))

        let sending = harness.model.send()
        try await Task.sleep(for: .milliseconds(20))
        harness.model.cancel()
        await sending?.value

        #expect(harness.model.phase == .failed("Cancelled"))
        #expect(harness.model.exchange == nil)
        #expect(harness.target.loads.isEmpty)
    }

    @Test func savingNamesUpdatesAndTracksChanges() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.transport.answer(endpoint, .init(body: videoResponse))
        await harness.model.send()?.value
        #expect(harness.model.hasUnsavedChanges)

        #expect(await harness.model.save())

        let saved = try #require(harness.library.requests.first)
        #expect(harness.library.requests.count == 1)
        #expect(saved.name == "ssp.example/openrtb2/auction")
        #expect(saved.request == harness.model.request)
        #expect(saved.exchange == harness.model.exchange)
        #expect(harness.model.savedID == saved.id)
        #expect(harness.model.name == saved.name)
        #expect(!harness.model.hasUnsavedChanges)

        harness.model.name = "Rewarded video"
        harness.model.request.headers.append(ClientHeader(name: "X-Test", value: "1"))
        #expect(harness.model.hasUnsavedChanges)
        #expect(await harness.model.save())
        #expect(harness.library.requests.map(\.name) == ["Rewarded video"])
        #expect(harness.library.requests.first?.id == saved.id)

        #expect(await harness.model.save(asNew: true))
        #expect(harness.library.requests.count == 2)
        #expect(harness.model.savedID != saved.id)
    }

    /// Debug later: a saved request reopens with its response, and Render shows that response on its device without
    /// sending anything.
    @Test func aSavedResponseRendersWithoutSending() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let response = ClientResponse(status: 200, headers: [:], body: videoResponse, bodyBytes: videoResponse.utf8.count,
                                      durationMilliseconds: 12, receivedAt: date, url: endpoint)
        let saved = SavedRequest(id: UUID(), name: "Fold video", createdAt: date, updatedAt: date, request: request(),
                                 exchange: ClientExchange(requestBody: rewardedVideoRequest, response: response, deviceID: "galaxy-z-fold"))

        harness.model.open(saved)
        #expect(harness.model.request == saved.request)
        #expect(harness.model.name == "Fold video")
        #expect(harness.model.exchange == saved.exchange)
        #expect(harness.model.exchangeOrigin == .saved)
        #expect(harness.model.phase == .received)

        await harness.model.render()

        #expect(harness.target.loads == [.init(request: rewardedVideoRequest, response: videoResponse, deviceID: "galaxy-z-fold", render: true)])
        #expect(harness.transport.requests.isEmpty)
    }

    @Test func aNewRequestStartsBlank() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.transport.answer(endpoint, .init(body: videoResponse))
        await harness.model.send()?.value

        harness.model.newRequest()

        #expect(harness.model.request.url.isEmpty)
        #expect(harness.model.request.body.isEmpty)
        #expect(harness.model.request.method == .post)
        #expect(harness.model.request.headers.map { "\($0.name): \($0.value)" } == ClientRequest.defaultHeaders().map { "\($0.name): \($0.value)" })
        #expect(harness.model.exchange == nil)
        #expect(harness.model.savedID == nil)
        #expect(harness.model.name.isEmpty)
        #expect(harness.model.phase == .idle)
    }
}

// MARK: - End to end

@MainActor
@Suite("Client: end to end", .serialized)
struct ClientEndToEndTests {
    /// The request says rewarded, the response says video (`mtype` 2): the simulator plays it as rewarded video on the
    /// iPhone 18 Pro, and in Simulated mode the bid request is the only request that reaches the network.
    @Test func aRewardedVideoRequestPlaysAsRewardedVideo() async throws {
        let transport = ScriptedTransport()
        transport.answer(endpoint, .init(body: videoResponse))
        let monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        let session = AdSession(services: .live, monitor: monitor, parseDebounce: .zero)
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let model = ClientModel(target: session, library: SavedRequestLibrary(store: SavedRequestStore(directory: directory.url)))
        model.request = request()

        await model.send()?.value
        for _ in 0..<200 where session.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }

        #expect(session.requestText == rewardedVideoRequest)
        #expect(session.responseText == videoResponse)
        #expect(session.device.id == "iphone-18-pro")
        #expect(session.selectedCandidate?.format == .video)
        #expect(session.placement == .rewarded)
        #expect(session.phase == .ready)
        #expect(session.isVAST)
        #expect(transport.requests.map(\.url.absoluteString) == [endpoint])
        #expect(monitor.liveEntries.first?.category == .bidRequest)
    }
}

// MARK: - Presentation

@MainActor
@Suite("Client: presentation")
struct ClientPresentationTests {
    @Test func statusLinesNameTheReason() {
        #expect(ClientPresentation.statusText(200) == "200 OK")
        #expect(ClientPresentation.statusText(204) == "204 No Content")
        #expect(ClientPresentation.statusText(299) == "299")
        #expect(ClientPresentation.statusTone(204) == .success)
        #expect(ClientPresentation.statusTone(307) == .redirect)
        #expect(ClientPresentation.statusTone(400) == .clientError)
        #expect(ClientPresentation.statusTone(503) == .serverError)
    }

    /// Copy as curl repeats what Send would put on the wire: the device's User-Agent unless the user set one, the
    /// monitor's Accept and Accept-Language, the user's headers and the body.
    @Test func theDraftCopiesAsTheCurlThatSendWouldBe() throws {
        let command = try ClientPresentation.curl(for: request(), userAgent: "UA/1", acceptLanguage: "en-US,en;q=0.9")
        #expect(command.contains("-H 'User-Agent: UA/1'"))
        #expect(command.contains("-H 'Accept: */*'"))
        #expect(command.contains("-H 'Accept-Language: en-US,en;q=0.9'"))
        #expect(command.contains("-H 'x-openrtb-version: 2.6'"))
        #expect(command.contains("--data-binary '" + rewardedVideoRequest + "'"))
        #expect(command.hasSuffix("--url '\(endpoint)'"))
        var custom = request()
        custom.headers.append(ClientHeader(name: "user-agent", value: "Exchange/2"))
        let overridden = try ClientPresentation.curl(for: custom, userAgent: "UA/1", acceptLanguage: "en")
        #expect(overridden.contains("-H 'user-agent: Exchange/2'"))
        #expect(!overridden.contains("UA/1"))
        #expect(throws: ClientRequest.Invalid.self) { try ClientPresentation.curl(for: ClientRequest(), userAgent: "UA", acceptLanguage: "en") }
    }

    @Test func savedRequestsAreFoundByNameURLAndMethod() {
        let date = Date(timeIntervalSince1970: 0)
        let saved = [SavedRequest(id: UUID(), name: "Rewarded video", createdAt: date, updatedAt: date, request: request(), exchange: nil),
                     SavedRequest(id: UUID(), name: "Banner", createdAt: date, updatedAt: date,
                                  request: request("https://dsp.example/bid", method: .get), exchange: nil)]
        #expect(ClientPresentation.filter(saved, by: "").count == 2)
        #expect(ClientPresentation.filter(saved, by: "reward").map(\.name) == ["Rewarded video"])
        #expect(ClientPresentation.filter(saved, by: "DSP.example").map(\.name) == ["Banner"])
        #expect(ClientPresentation.filter(saved, by: "get banner").map(\.name) == ["Banner"])
        #expect(ClientPresentation.filter(saved, by: "nothing").isEmpty)
    }
}
