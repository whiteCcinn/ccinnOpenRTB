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
        var rendering: ExchangeRendering
    }

    let monitor: NetworkMonitor
    var device: DeviceProfile = DeviceCatalog.defaultDevice
    var mode: TrackingMode { monitor.mode }
    private(set) var loads: [Load] = []

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
    }

    func loadExchange(request: String, response: String, device: DeviceProfile?, rendering: ExchangeRendering) async -> Bool {
        loads.append(Load(request: request, response: response, deviceID: device?.id, rendering: rendering))
        return rendering == .always || (rendering == .unlessRealMode && mode != .real)
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

    /// A hand-edited file with one header id twice: the rows get ids of their own, so the editor can tell them apart.
    @Test func duplicateHeaderIDsAreMadeUnique() throws {
        let id = UUID()
        let draft = request(headers: [ClientHeader(id: id, name: "A", value: "1"), ClientHeader(id: id, name: "B", value: "2")])
        let decoded = try JSONDecoder().decode(ClientRequest.self, from: JSONEncoder().encode(draft))
        #expect(Set(decoded.headers.map(\.id)).count == 2)
        #expect(decoded.headers.map(\.name) == ["A", "B"])
        #expect(decoded.headers.first?.id == id)
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

    /// Deleting removes every file that holds the request (a Finder copy too): it never comes back on the next launch.
    @Test func deletingRemovesEveryCopy() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let store = SavedRequestStore(directory: directory.url)
        let item = saved("Secret")
        let keep = saved("Keep")
        try await store.write(item)
        try await store.write(keep)
        try FileManager.default.copyItem(at: directory.url.appendingPathComponent("\(item.id.uuidString).json"),
                                         to: directory.url.appendingPathComponent("Secret copy.json"))

        try await store.delete(id: item.id)

        #expect(try await store.loadAll().requests == [keep])
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("Secret copy.json").path))
    }

    /// A request too large to be read back is refused when saving, not lost on the next launch.
    @Test func aRequestTooLargeToReadBackIsNotWritten() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let store = SavedRequestStore(directory: directory.url, maxFileBytes: 1_024)

        await #expect(throws: (any Error).self) { try await store.write(saved("Big")) }

        #expect(try await store.loadAll().requests.isEmpty)
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

    @Test func aFailedDeleteKeepsTheRequestAndSaysSo() async throws {
        let directory = TemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path)
            directory.cleanUp()
        }
        let library = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))
        let kept = item("Kept", at: 1)
        #expect(await library.save(kept))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.url.path)

        #expect(await library.delete(kept.id) == false)

        #expect(library.requests.map(\.id) == [kept.id])
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
        #expect(harness.target.loads == [.init(request: rewardedVideoRequest, response: videoResponse, deviceID: "iphone-18-pro",
                                               rendering: .unlessRealMode)])
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

        #expect(harness.target.loads.map(\.rendering) == [.unlessRealMode])
        #expect(harness.model.simulatorNote?.contains("Render") == true)

        // Render is the explicit action Real mode waits for: it renders (and so sends the bid's trackers).
        await harness.model.render()
        #expect(harness.target.loads.map(\.rendering) == [.unlessRealMode, .always])
        #expect(harness.model.simulatorNote == nil)
    }

    /// A GET sends no body, so none goes to the simulator either (not a stale body left in the hidden editor).
    @Test func aGETExchangeCarriesNoBody() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        harness.transport.answer(endpoint, .init(body: videoResponse))
        harness.model.request.method = .get

        await harness.model.send()?.value

        #expect(harness.transport.requests.first?.body == nil)
        #expect(harness.model.exchange?.requestBody == "")
        #expect(harness.target.loads.first?.request == "")
    }

    /// ⌘S twice before the first write lands saves one request, not two.
    @Test func concurrentSavesMakeOneRequest() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }

        async let first = harness.model.save()
        async let second = harness.model.save()
        let results = await [first, second]

        #expect(results.filter { $0 }.count == 1)
        #expect(harness.library.requests.count == 1)
    }

    /// Opening another request while a save is in flight: the save lands, and the tab stays on what was opened.
    @Test func aSaveDoesNotRelabelARequestOpenedMeanwhile() async throws {
        let harness = Harness()
        defer { harness.directory.cleanUp() }
        let date = Date(timeIntervalSince1970: 1)
        let other = SavedRequest(id: UUID(), name: "Other", createdAt: date, updatedAt: date, request: request("https://other.example/bid"),
                                 exchange: nil)

        let saving = Task { await harness.model.save() }
        for _ in 0..<1_000 where !harness.model.isSaving { await Task.yield() }
        #expect(harness.model.isSaving)
        harness.model.open(other)
        #expect(await saving.value)

        #expect(harness.model.savedID == other.id)
        #expect(harness.model.name == "Other")
        #expect(harness.model.request.url == "https://other.example/bid")
        #expect(harness.library.requests.map(\.name) == ["ssp.example/openrtb2/auction"])
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
        for _ in 0..<2_000 where harness.model.sendWarning == nil { try await Task.sleep(for: .milliseconds(5)) }

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
        harness.transport.answer(endpoint, .init(body: videoResponse, delay: .heldUntilCancelled))

        let sending = harness.model.send()
        for _ in 0..<2_000 where harness.transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(harness.transport.requests.count == 1)
        harness.model.cancel()
        await sending?.value

        #expect(harness.model.phase == .failed("Cancelled"))
        #expect(harness.model.exchange == nil)
        #expect(harness.target.loads.isEmpty)
        // The request itself was stopped, not just ignored.
        await harness.monitor.waitUntilIdle()
        #expect(harness.monitor.inFlightCount == 0)
        #expect(harness.monitor.liveEntries.first?.isFailure == true)
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

        #expect(harness.target.loads == [.init(request: rewardedVideoRequest, response: videoResponse, deviceID: "galaxy-z-fold", rendering: .always)])
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
        for _ in 0..<1_000 where session.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }

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

@MainActor
@Suite("Client: Real mode with a session", .serialized)
struct ClientRealModeTests {
    /// Real mode: the response reaches the editors, nothing renders and no tracker goes out — until Render.
    @Test func realModeSendsNoTrackerUntilRender() async throws {
        let transport = ScriptedTransport()
        transport.answer(endpoint, .init(body: videoResponse))
        let monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        let session = AdSession(services: .live, monitor: monitor, parseDebounce: .zero)
        monitor.mode = .real  // as after a confirmation
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let model = ClientModel(target: session, library: SavedRequestLibrary(store: SavedRequestStore(directory: directory.url)))
        model.request = request()

        await model.send()?.value

        #expect(session.responseText == videoResponse)
        #expect(session.phase == .idle)
        #expect(transport.requests.map(\.url.absoluteString) == [endpoint])
        #expect(monitor.liveEntries.map(\.category) == [.bidRequest])

        await model.render()
        #expect(session.phase != .idle)
    }

    /// The render decision is taken after the parse: a switch to Real mode while it runs is honoured.
    @Test func aSwitchToRealModeDuringTheParseStopsTheAutomaticRender() async throws {
        let gate = DispatchSemaphore(value: 0)
        var services = AdKitServices.live
        services.parseInput = { text, request in
            gate.wait()
            return InputParser.parse(text, request: request)
        }
        let monitor = NetworkMonitor(transport: ScriptedTransport(), publishInterval: .zero)
        let session = AdSession(services: services, monitor: monitor, parseDebounce: .zero)

        let loading = Task { await session.loadExchange(request: rewardedVideoRequest, response: videoResponse, device: nil, rendering: .unlessRealMode) }
        for _ in 0..<1_000 where session.responseText.isEmpty { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))
        monitor.mode = .real
        for _ in 0..<8 { gate.signal() }

        #expect(await loading.value == false)
        #expect(session.phase == .idle)
        #expect(session.responseText == videoResponse)
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
        #expect(command.contains("--data-raw '" + rewardedVideoRequest + "'"))
        #expect(command.hasSuffix("--url '\(endpoint)'"))
        var custom = request()
        custom.headers.append(ClientHeader(name: "user-agent", value: "Exchange/2"))
        let overridden = try ClientPresentation.curl(for: custom, userAgent: "UA/1", acceptLanguage: "en")
        #expect(overridden.contains("-H 'user-agent: Exchange/2'"))
        #expect(!overridden.contains("UA/1"))
        #expect(throws: ClientRequest.Invalid.self) { try ClientPresentation.curl(for: ClientRequest(), userAgent: "UA", acceptLanguage: "en") }
    }

    /// A body the monitor did not keep (over 512 KiB) cannot be repeated: no curl rather than a wrong one.
    @Test func curlOfAnEntryNeedsItsBody() {
        let entry = NetworkEntry(sequence: 1, category: .bidRequest, trigger: "bid request", source: "client", template: endpoint, url: endpoint,
                                 method: "POST", state: .completed(status: 200), requestBodyBytes: 600_000)
        #expect(NetworkPresentation.curl(for: entry, body: nil) == nil)
        #expect(NetworkPresentation.curl(for: entry, body: Data("{}".utf8))?.contains("--data-raw '{}'") == true)
        let get = NetworkEntry(sequence: 2, category: .content, trigger: "t", source: "s", template: endpoint, url: endpoint, state: .simulated)
        #expect(NetworkPresentation.curl(for: get, body: nil) != nil)
        var empty = entry
        empty.requestBodyBytes = 0
        #expect(NetworkPresentation.curl(for: empty, body: nil) != nil)
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

// MARK: - Export and import

@Suite("Saved requests: archive")
struct SavedRequestArchiveTests {
    private func saved(_ name: String, updatedAt: TimeInterval, id: UUID = UUID()) -> SavedRequest {
        let date = Date(timeIntervalSince1970: updatedAt)
        let response = ClientResponse(status: 200, headers: ["Content-Type": "application/json"], body: videoResponse,
                                      bodyBytes: videoResponse.utf8.count, durationMilliseconds: 42.5, receivedAt: date, url: endpoint)
        return SavedRequest(id: id, name: name, createdAt: date, updatedAt: date, request: request(),
                            exchange: ClientExchange(requestBody: rewardedVideoRequest, response: response, deviceID: "iphone-18-pro"))
    }

    @Test func anArchiveRoundTripsEveryRequestExactly() throws {
        let requests = [saved("A", updatedAt: 1_800_000_000), saved("B", updatedAt: 1_800_000_100)]
        let data = try SavedRequestArchive.encode(requests, exportedAt: Date(timeIntervalSince1970: 1_800_000_200), appVersion: "1.1.0")

        let decoded = try SavedRequestArchive.decode(data)

        #expect(decoded.requests == requests)
        #expect(decoded.unreadable == 0)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["format"] as? String == SavedRequestArchive.formatIdentifier)
        #expect(root["version"] as? Int == SavedRequestArchive.currentVersion)
        #expect(root["appVersion"] as? String == "1.1.0")
    }

    /// Dates are kept to the millisecond.
    @Test func datesKeepMilliseconds() throws {
        let precise = saved("A", updatedAt: 1_800_000_000.123_456)
        let data = try SavedRequestArchive.encode([precise], exportedAt: Date(), appVersion: "1.1.0")
        let back = try #require(try SavedRequestArchive.decode(data).requests.first)
        #expect(abs(back.updatedAt.timeIntervalSince(precise.updatedAt)) < SavedRequestCoding.datePrecision)
        #expect(!SavedRequestCoding.isNewer(back.updatedAt, than: precise.updatedAt))
        #expect(!SavedRequestCoding.isNewer(precise.updatedAt, than: back.updatedAt))
    }

    /// One damaged request does not cost the others.
    @Test func damagedEntriesAreSkippedAndCounted() throws {
        let good = saved("Good", updatedAt: 1_800_000_000)
        let data = try SavedRequestArchive.encode([good], exportedAt: Date(), appVersion: "1.1.0")
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try #require(root["requests"] as? [Any])
        entries.append(["name": "no id"])
        entries.append(42)
        root["requests"] = entries
        let damaged = try JSONSerialization.data(withJSONObject: root)

        let decoded = try SavedRequestArchive.decode(damaged)

        #expect(decoded.requests == [good])
        #expect(decoded.unreadable == 2)
    }

    /// A single saved-request file (copied from the Requests folder) imports too.
    @Test func aSingleSavedRequestFileIsAccepted() throws {
        let one = saved("One", updatedAt: 1_800_000_000)
        let data = try SavedRequestCoding.encoder().encode(one)
        #expect(try SavedRequestArchive.decode(data).requests == [one])
    }

    @Test func otherFilesAreRefusedWithAReason() throws {
        #expect(throws: SavedRequestArchive.Failure.notAnArchive) { try SavedRequestArchive.decode(Data("not json".utf8)) }
        #expect(throws: SavedRequestArchive.Failure.notAnArchive) { try SavedRequestArchive.decode(Data(#"{"id":"x","seatbid":[]}"#.utf8)) }
        #expect(throws: SavedRequestArchive.Failure.notAnArchive) {
            try SavedRequestArchive.decode(Data(#"{"format":"something.else","version":1,"requests":[]}"#.utf8))
        }
        #expect(throws: SavedRequestArchive.Failure.newerVersion(99)) {
            try SavedRequestArchive.decode(Data(#"{"format":"\#(SavedRequestArchive.formatIdentifier)","version":99,"requests":[]}"#.utf8))
        }
        #expect(throws: SavedRequestArchive.Failure.tooLarge(limit: 16)) { try SavedRequestArchive.decode(Data(count: 17), maxBytes: 16) }
        #expect(SavedRequestArchive.Failure.notAnArchive.message.isEmpty == false)
    }
}

@MainActor
@Suite("Saved requests: export and import", .serialized)
struct SavedRequestMigrationTests {
    private func saved(_ name: String, updatedAt: TimeInterval, id: UUID = UUID()) -> SavedRequest {
        let date = Date(timeIntervalSince1970: updatedAt)
        return SavedRequest(id: id, name: name, createdAt: date, updatedAt: date, request: request(), exchange: nil)
    }

    /// Switching computers: export everything on one Mac, import it with one click on the other.
    @Test func everythingMovesToAnotherMac() async throws {
        let old = TemporaryDirectory()
        let new = TemporaryDirectory()
        defer { old.cleanUp(); new.cleanUp() }
        let source = SavedRequestLibrary(store: SavedRequestStore(directory: old.url))
        for (index, name) in ["Banner", "Native", "Rewarded video"].enumerated() {
            #expect(await source.save(saved(name, updatedAt: 1_800_000_000 + Double(index))))
        }

        let archive = try #require(await source.exportArchive(appVersion: "1.1.0"))
        let target = SavedRequestLibrary(store: SavedRequestStore(directory: new.url))
        let result = try await target.importArchive(archive)

        #expect(result == SavedRequestLibrary.ImportResult(added: 3, updated: 0, unchanged: 0, unreadable: 0, failed: 0))
        #expect(target.requests == source.requests)
        let relaunched = SavedRequestLibrary(store: SavedRequestStore(directory: new.url))
        await relaunched.loadIfNeeded()
        #expect(relaunched.requests == source.requests)
        #expect(target.lastNotice == "Imported 3 requests.")
    }

    /// Merged by id: the more recently updated copy wins, so importing twice changes nothing and never loses newer work.
    @Test func importingMergesByIDAndKeepsTheNewer() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))
        let sharedOld = UUID()
        let sharedNew = UUID()
        #expect(await library.save(saved("Local is newer", updatedAt: 2_000, id: sharedNew)))
        #expect(await library.save(saved("Local is older", updatedAt: 1_000, id: sharedOld)))
        let incoming = [saved("Archive is newer", updatedAt: 3_000, id: sharedOld), saved("Archive is older", updatedAt: 1_500, id: sharedNew),
                        saved("Only in the archive", updatedAt: 500)]
        let archive = try SavedRequestArchive.encode(incoming, exportedAt: Date(), appVersion: "1.1.0")

        let first = try await library.importArchive(archive)
        let second = try await library.importArchive(archive)

        #expect(first == SavedRequestLibrary.ImportResult(added: 1, updated: 1, unchanged: 1, unreadable: 0, failed: 0))
        #expect(second == SavedRequestLibrary.ImportResult(added: 0, updated: 0, unchanged: 3, unreadable: 0, failed: 0))
        #expect(Set(library.requests.map(\.name)) == ["Archive is newer", "Local is newer", "Only in the archive"])
        #expect(library.lastNotice == "Nothing new: 3 requests are already here.")
    }

    /// Re-importing your own fresh export (dates with sub-millisecond parts in memory) changes nothing.
    @Test func reimportingAFreshExportChangesNothing() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))
        for offset in [0.000_4, 0.000_6, 0.123_456] {
            #expect(await library.save(saved("At \(offset)", updatedAt: 1_800_000_000 + offset)))
        }

        let archive = try #require(await library.exportArchive(appVersion: "1.1.0"))
        let result = try await library.importArchive(archive)

        #expect(result == SavedRequestLibrary.ImportResult(added: 0, updated: 0, unchanged: 3, unreadable: 0, failed: 0))
    }

    @Test func aFileThatIsNotAnArchiveChangesNothing() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))
        #expect(await library.save(saved("Kept", updatedAt: 1)))

        await #expect(throws: SavedRequestArchive.Failure.notAnArchive) { try await library.importArchive(Data("{}".utf8)) }

        #expect(library.requests.map(\.name) == ["Kept"])
    }

    /// One click on the new Mac: the exported file is read and imported; a file that cannot be read says why.
    @Test func importingAFileReadsItAndSaysWhatHappened() async throws {
        let old = TemporaryDirectory()
        let new = TemporaryDirectory()
        defer { old.cleanUp(); new.cleanUp() }
        let source = SavedRequestLibrary(store: SavedRequestStore(directory: old.url))
        #expect(await source.save(saved("Banner", updatedAt: 1)))
        let file = old.url.deletingLastPathComponent().appendingPathComponent("export.json")
        try await source.exportArchive(to: file, appVersion: "1.1.0")
        let target = SavedRequestLibrary(store: SavedRequestStore(directory: new.url))

        let result = try await target.importArchive(contentsOf: file)
        #expect(result.added == 1)
        #expect(target.requests.map(\.name) == ["Banner"])

        let missing = old.url.deletingLastPathComponent().appendingPathComponent("missing.json")
        await #expect(throws: SavedRequestArchive.Failure.self) { try await target.importArchive(contentsOf: missing) }
        #expect(target.lastError != nil)
        #expect(target.lastNotice == nil)
        #expect(target.requests.map(\.name) == ["Banner"])
    }

    /// The export holds credentials: written readable only by the user.
    @Test func theExportFileIsPrivate() async throws {
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let library = SavedRequestLibrary(store: SavedRequestStore(directory: directory.url))
        #expect(await library.save(saved("A", updatedAt: 1)))
        let file = directory.url.deletingLastPathComponent().appendingPathComponent("export.json")

        try await library.exportArchive(to: file, appVersion: "1.1.0")

        #expect(directory.permissions(file) == 0o600)
        #expect(try SavedRequestArchive.decode(Data(contentsOf: file)).requests.map(\.name) == ["A"])
        #expect(library.lastNotice == "Exported 1 request.")
    }
}

// MARK: - Redirects

@Suite("Client: redirects")
struct ClientRedirectTests {
    /// Requests saved by 1.1.0 have no redirect setting: they keep 1.1.0's behaviour (within the origin).
    @Test func aRequestSavedBy110FollowsWithinTheOrigin() throws {
        let json = #"{"method":"POST","url":"https://ssp.example/a","headers":[],"body":"{}"}"#
        let decoded = try JSONDecoder().decode(ClientRequest.self, from: Data(json.utf8))
        #expect(decoded.redirects == .sameOrigin)
        var all = decoded
        all.redirects = .all
        #expect(try JSONDecoder().decode(ClientRequest.self, from: JSONEncoder().encode(all)).redirects == .all)
        #expect(try all.composed().redirects == .all)
    }

    @Test func theChainIsKeptWithTheResponse() throws {
        let first = UUID()
        let second = UUID()
        let composed = ComposedResponse(status: 200, headers: [:], body: Data("{}".utf8), url: try #require(URL(string: "https://b.example/x")),
                                        entryID: first, responseEntryID: second, duration: 0.2, timings: nil,
                                        chain: [ComposedHop(entryID: first, method: "POST", url: endpoint, status: 307, location: "https://b.example/x",
                                                            bodyBytes: 10, duration: 0.05, note: nil, wasSent: true, failure: nil),
                                                ComposedHop(entryID: second, method: "POST", url: "https://b.example/x", status: 200, location: nil,
                                                            bodyBytes: 10, duration: 0.15, note: "Not carried to another origin: Authorization",
                                                            wasSent: true, failure: nil)])
        let response = ClientResponse(composed, receivedAt: Date(timeIntervalSince1970: 0))
        #expect(response.chain.map(\.status) == [307, 200])
        #expect(response.chain.first?.location == "https://b.example/x")
        #expect(response.chain.last?.note == "Not carried to another origin: Authorization")
        #expect(abs((response.chain.first?.durationMilliseconds ?? 0) - 50) < 0.001)
        #expect(response.redirectCount == 1)
        #expect(try JSONDecoder().decode(ClientResponse.self, from: JSONEncoder().encode(response)) == response)
    }

    /// Responses saved by 1.1.0 have no chain.
    @Test func aResponseSavedBy110HasNoChain() throws {
        let json = #"{"status":200,"headers":{},"body":"{}","bodyBytes":2,"durationMilliseconds":5,"receivedAt":0,"url":"https://a.example/"}"#
        let decoded = try JSONDecoder().decode(ClientResponse.self, from: Data(json.utf8))
        #expect(decoded.chain.isEmpty)
        #expect(decoded.redirectStop == nil)
        #expect(decoded.redirectCount == 0)
    }

    @Test func aRedirectNotFollowedSaysWhyAndHowToFollowIt() {
        let stop = RedirectStop.notFollowed(.sameOrigin, location: "https://other.example/a")
        let response = ClientResponse(status: 307, headers: ["Location": "https://other.example/a"], body: "", bodyBytes: 0, durationMilliseconds: 1,
                                      receivedAt: Date(), url: endpoint, redirectStop: stop.description, stopCanBeFollowed: stop.canBeFollowed)
        let note = ClientModel.leftAloneNote(for: response)
        #expect(note.contains("another origin"))
        #expect(note.contains("Follow"))
        #expect(!note.contains(".."))
        #expect(response.canFollowFurther)
    }

    /// A loop (or too many hops, a target that is not http) cannot be fixed by following more: no such advice.
    @Test func aDeadEndOffersNoFollowing() {
        let stop = RedirectStop.loop(endpoint)
        let response = ClientResponse(status: 307, headers: [:], body: "", bodyBytes: 0, durationMilliseconds: 1, receivedAt: Date(), url: endpoint,
                                      redirectStop: stop.description, stopCanBeFollowed: stop.canBeFollowed)
        let note = ClientModel.leftAloneNote(for: response)
        #expect(note.contains("loop"))
        #expect(!note.contains("Follow"))
        #expect(!note.contains(".."))
        #expect(!response.canFollowFurther)
    }

    /// A newer build's setting, or a hand-edited file: the saved request still opens, with the safe default.
    @Test func unknownValuesFallBackInsteadOfLosingTheRequest() throws {
        let request = #"{"method":"POST","url":"https://ssp.example/a","headers":[],"body":"{}","redirects":"teleport"}"#
        #expect(try JSONDecoder().decode(ClientRequest.self, from: Data(request.utf8)).redirects == .sameOrigin)
        let response = #"{"status":200,"headers":{},"body":"{}","bodyBytes":2,"durationMilliseconds":5,"receivedAt":0,"url":"https://a.example/","chain":[{"bad":1}]}"#
        #expect(try JSONDecoder().decode(ClientResponse.self, from: Data(response.utf8)).chain.isEmpty)
        let defaults = try #require(UserDefaults(suiteName: "ccinn.test.\(UUID().uuidString)"))
        defaults.set("teleport", forKey: NetworkPreferences.clientRedirectsKey)
        #expect(NetworkPreferences.clientRedirects(in: defaults) == .sameOrigin)
    }

    /// The stop and whether it can be followed survive the saved-request file format.
    @Test func theStopSurvivesTheSavedFile() throws {
        let stop = RedirectStop.notFollowed(.sameOrigin, location: "https://other.example/a")
        let response = ClientResponse(status: 307, headers: [:], body: "", bodyBytes: 0, durationMilliseconds: 1, receivedAt: Date(timeIntervalSince1970: 1),
                                      url: endpoint, redirectStop: stop.description, stopCanBeFollowed: true)
        let saved = SavedRequest(id: UUID(), name: "x", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), request: request(),
                                 exchange: ClientExchange(requestBody: "", response: response, deviceID: nil))
        let decoded = try SavedRequestCoding.decoder().decode(SavedRequest.self, from: SavedRequestCoding.encoder().encode(saved))
        #expect(decoded.exchange?.response.redirectStop == stop.description)
        #expect(decoded.exchange?.response.canFollowFurther == true)
    }

    @Test func copyAsCurlFollowsWhenTheRequestDoes() throws {
        var all = request()
        all.redirects = .all
        #expect(try ClientPresentation.curl(for: all, userAgent: "UA", acceptLanguage: "en").contains("--location"))
        #expect(try !ClientPresentation.curl(for: request(), userAgent: "UA", acceptLanguage: "en").contains("--location"))
    }
}

@MainActor
@Suite("Client: redirects with a model", .serialized)
struct ClientRedirectModelTests {
    @Test func newRequestsTakeTheDefaultFromSettings() {
        let target = RecordingSimulatorTarget(monitor: NetworkMonitor(transport: ScriptedTransport(), publishInterval: .zero))
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let model = ClientModel(target: target, library: SavedRequestLibrary(store: SavedRequestStore(directory: directory.url)),
                                defaultRedirects: { .all })
        #expect(model.request.redirects == .all)
        model.request.redirects = .none
        model.newRequest()
        #expect(model.request.redirects == .all)
    }

    /// One click from a redirect that was not followed to the whole chain.
    @Test func followAllRedirectsAndSendFollowsTheChain() async throws {
        let transport = ScriptedTransport()
        transport.answer(endpoint, .init(status: 307, headers: ["Location": "https://other.example/auction"]))
        transport.answer("https://other.example/auction", .init(body: videoResponse))
        let monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        let target = RecordingSimulatorTarget(monitor: monitor)
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let model = ClientModel(target: target, library: SavedRequestLibrary(store: SavedRequestStore(directory: directory.url)),
                                defaultRedirects: { .sameOrigin })
        model.request = request()

        await model.send()?.value
        #expect(model.exchange?.response.status == 307)
        #expect(model.exchange?.response.canFollowFurther == true)
        #expect(model.canFollowAllRedirects)
        #expect(model.followTarget == "other.example")
        #expect(target.loads.isEmpty)

        await model.followAllRedirectsAndSend()?.value

        // Followed for that send only: the request's own setting is unchanged.
        #expect(model.request.redirects == .sameOrigin)
        #expect(model.prefersRedirectsTab)
        #expect(model.exchange?.response.status == 200)
        #expect(model.exchange?.response.redirectCount == 1)
        #expect(model.exchange?.response.chain.map(\.url) == [endpoint, "https://other.example/auction"])
        #expect(target.loads.count == 1)
        #expect(!model.canFollowAllRedirects)
    }

    /// The button follows the request that got the answer: once the draft is edited, it is gone.
    @Test func editingTheDraftWithdrawsFollowing() async throws {
        let transport = ScriptedTransport()
        transport.answer(endpoint, .init(status: 307, headers: ["Location": "https://other.example/auction"]))
        let target = RecordingSimulatorTarget(monitor: NetworkMonitor(transport: transport, publishInterval: .zero))
        let directory = TemporaryDirectory()
        defer { directory.cleanUp() }
        let model = ClientModel(target: target, library: SavedRequestLibrary(store: SavedRequestStore(directory: directory.url)),
                                defaultRedirects: { .sameOrigin })
        model.request = request()
        await model.send()?.value
        #expect(model.canFollowAllRedirects)

        model.request.headers.append(ClientHeader(name: "X-Internal-Token", value: "t"))

        #expect(!model.canFollowAllRedirects)
        #expect(model.followAllRedirectsAndSend() == nil)
        #expect(transport.requests.count == 1)
    }
}
