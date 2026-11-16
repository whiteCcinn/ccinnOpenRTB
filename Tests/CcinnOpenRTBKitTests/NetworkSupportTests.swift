import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTBKit

@Suite("data: URLs")
struct DataURLTests {
    @Test func decodesBase64AndPercentEncodedPayloads() throws {
        let base64 = try #require(DataURL.decode("data:image/png;base64,iVBORw0KGgo="))
        #expect(base64.mimeType == "image/png")
        #expect(Array(base64.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])

        let text = try #require(DataURL.decode("data:text/xml;charset=utf-8,%3CVAST%20version%3D%224.2%22%2F%3E"))
        #expect(String(decoding: text.data, as: UTF8.self) == "<VAST version=\"4.2\"/>")
        #expect(text.charset == "utf-8")

        let plain = try #require(DataURL.decode("data:,Hello%2C%20World"))
        #expect(plain.mimeType == "text/plain")
        #expect(String(decoding: plain.data, as: UTF8.self) == "Hello, World")
    }

    @Test func toleratesWhitespaceMissingPaddingAndURLSafeBase64() throws {
        #expect(try #require(DataURL.decode("data:text/plain;base64,SGVs bG8")).data == Data("Hello".utf8))
        #expect(try #require(DataURL.decode("DATA:application/octet-stream;BASE64,-_8")).data == Data([0xFB, 0xFF]))
    }

    @Test(arguments: ["data:text/plain;base64", "https://x.example", "data:;base64,A", "", "data"])
    func rejectsMalformedInput(text: String) {
        #expect(DataURL.decode(text) == nil)
    }

    @Test func invalidPercentEscapesStayVerbatim() throws {
        #expect(String(decoding: try #require(DataURL.decode("data:,100%ZZ%")).data, as: UTF8.self) == "100%ZZ%")
    }
}

@Suite("Text decoding")
struct TextDecodingTests {
    @Test func honoursBOMsCharsetAndXMLDeclaration() {
        #expect(TextDecoding.string(from: Data([0xEF, 0xBB, 0xBF]) + Data("<VAST/>".utf8)) == "<VAST/>")
        let latin1 = Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><AdTitle>Caf\u{E9}</AdTitle>".data(using: .isoLatin1) ?? Data())
        #expect(TextDecoding.string(from: latin1).hasSuffix("Café</AdTitle>"))
        #expect(TextDecoding.string(from: Data([0x43, 0x61, 0x66, 0xE9]), charset: "windows-1252") == "Café")
        let utf16 = "<VAST/>".data(using: .utf16) ?? Data()
        #expect(TextDecoding.string(from: utf16) == "<VAST/>")
    }

    @Test func invalidUTF8FallsBackInsteadOfFailing() {
        #expect(TextDecoding.string(from: Data([0xFF, 0x41])) == "\u{FF}A")
    }
}

@Suite("URL text and macros")
struct URLTextTests {
    @Test func hostAndPathWorkOnTemplates() {
        #expect(URLText.hostAndPath("https://user:pw@ads.example.com:8443/imp/1?e=[ERRORCODE]#x") == "ads.example.com:8443/imp/1")
        #expect(URLText.host("https://ADS.example.com:8443/imp") == "ads.example.com")
        #expect(URLText.host("http://[::1]:8080/x") == "::1")
        #expect(URLText.host("about:blank") == nil)
        #expect(URLText.scheme("HTTPS://x") == "https")
        #expect(URLText.scheme("not a url") == nil)
    }

    @Test func queryItemsKeepOrderAndDecode() {
        let items = URLText.queryItems("https://t.example/e?ev=start&price=${AUCTION_PRICE}&ua=Mozilla%2F5.0&flag#frag")
        #expect(items.map(\.name) == ["ev", "price", "ua", "flag"])
        #expect(items.map(\.value) == ["start", "${AUCTION_PRICE}", "Mozilla/5.0", ""])
    }

    @Test func requestURLEncodesLeftoverMacros() throws {
        let url = try #require(URLText.requestURL("https://t.example/e?code=[ERRORCODE]&x={y}"))
        #expect(url.host == "t.example")
        #expect(URLText.requestURL("::not a url") == nil)
        #expect(URLText.requestURL("/relative/path") == nil)
    }

    @Test func findsOpenRTBAndVASTMacros() {
        let text = "https://t.example/?p=${AUCTION_PRICE:B64}&e=[ERRORCODE]&ip=http://[::1]/&a=[a]&c=${}&t=[TIMESTAMP]"
        #expect(MacroTokens.find(in: text).map(\.text) == ["${AUCTION_PRICE:B64}", "[ERRORCODE]", "[TIMESTAMP]"])
        #expect(MacroTokens.find(in: "[[[[").isEmpty)
    }
}

@Suite("Copy as curl")
struct CurlCommandTests {
    @Test func quotesEverythingAndDisablesGlobbing() {
        let command = CurlCommand.make(url: "https://t.example/e?code=[ERRORCODE]&q=it's $HOME;rm -rf /",
                                       headers: ["User-Agent": "Mozilla/5.0 (iPhone)", "Accept": "*/*"])
        #expect(command == "curl --globoff -H 'Accept: */*' -H 'User-Agent: Mozilla/5.0 (iPhone)' --url 'https://t.example/e?code=[ERRORCODE]&q=it'\\''s $HOME;rm -rf /'")
    }

    @Test func urlsStartingWithADashAndControlCharactersAreSafe() {
        #expect(CurlCommand.make(url: "-o /tmp/x") == "curl --globoff --url '-o /tmp/x'")
        #expect(CurlCommand.make(url: "https://t.example/a\nb\u{0}") == "curl --globoff --url 'https://t.example/a%0Ab%00'")
        #expect(CurlCommand.make(url: "https://t.example/", method: "post") == "curl --globoff -X 'POST' --url 'https://t.example/'")
    }
}

@Suite("Network log")
struct NetworkLogTests {
    private func entry(parent: UUID? = nil) -> NetworkEntry {
        NetworkEntry(parentID: parent, sequence: 0, category: .event, trigger: "t", source: "s", template: "u", url: "u", state: .simulated)
    }

    @Test func staysConsistentUnderHeavyEviction() {
        var log = NetworkLog(capacity: 1_000)
        var ids: [UUID] = []
        var parent: UUID?
        for index in 0..<25_000 {
            let stored = log.append(entry(parent: index % 10 == 0 ? nil : parent))
            if index % 10 == 0 { parent = stored.id }
            ids.append(stored.id)
        }
        #expect(log.count == 1_000)
        let entries = log.entries
        #expect(entries.first?.sequence == 24_001)
        #expect(entries.last?.sequence == 25_000)
        #expect(zip(entries, entries.dropFirst()).allSatisfy { $0.sequence + 1 == $1.sequence })
        // Every live id resolves; every dropped id is gone; no entry points at a dropped parent.
        #expect(ids.suffix(1_000).allSatisfy { log.entry($0) != nil })
        #expect(ids.prefix(24_000).allSatisfy { log.entry($0) == nil })
        let live = Set(entries.map(\.id))
        #expect(entries.allSatisfy { $0.parentID.map(live.contains) ?? true })
        #expect(log.update(ids[24_500]) { $0.trigger = "changed" })
        #expect(log.entry(ids[24_500])?.trigger == "changed")
        #expect(!log.update(ids[0]) { $0.trigger = "gone" })
    }

    @Test func updatesCannotChangeIdentity() throws {
        var log = NetworkLog(capacity: 10)
        let stored = log.append(entry())
        log.update(stored.id) { entry in
            entry.id = UUID()
            entry.sequence = 99
            entry.parentID = UUID()
        }
        let after = try #require(log.entry(stored.id))
        #expect(after.sequence == stored.sequence)
        #expect(after.parentID == nil)
    }

    @Test func childrenAreListedInOrder() {
        var log = NetworkLog(capacity: 10)
        let root = log.append(entry())
        let a = log.append(entry(parent: root.id))
        let b = log.append(entry(parent: root.id))
        #expect(log.children(of: root.id).map(\.id) == [a.id, b.id])
    }

    @Test func selfParentIsDropped() {
        var log = NetworkLog(capacity: 10)
        let id = UUID()
        var looped = entry(parent: id)
        looped.id = id
        #expect(log.append(looped).parentID == nil)
    }
}

@Suite("Tree, waterfall and filter")
struct NetworkViewModelTests {
    private func entry(_ sequence: Int, parent: UUID? = nil, category: TrackerCategory = .event, start: Double = 0, end: Double? = nil,
                       state: NetworkEntryState = .simulated, delivery: NetworkDelivery = .simulated, url: String = "https://t.example/") -> NetworkEntry {
        let origin = Date(timeIntervalSince1970: 1_000)
        return NetworkEntry(parentID: parent, sequence: sequence, startedAt: origin.addingTimeInterval(start),
                            finishedAt: end.map { origin.addingTimeInterval($0) }, category: category, trigger: "t\(sequence)", source: "bid",
                            template: url, url: url, state: state, delivery: delivery)
    }

    @Test func buildsNestedChainsInOrder() {
        let wrapper = entry(1, category: .content)
        let wrapper2 = entry(2, parent: wrapper.id, category: .content)
        let inline = entry(3, parent: wrapper2.id, category: .content)
        let impression = entry(4, category: .impression)
        let hop = entry(5, parent: impression.id)
        let tree = NetworkTree.build([wrapper, wrapper2, inline, impression, hop])
        #expect(tree.map(\.id) == [wrapper.id, impression.id])
        #expect(tree[0].children?.first?.children?.first?.id == inline.id)
        #expect(tree[0].children?.first?.children?.first?.children == nil)
        #expect(tree[1].children?.map(\.id) == [hop.id])
        #expect(NetworkTree.ancestors(of: inline.id, in: [wrapper, wrapper2, inline]) == [wrapper.id, wrapper2.id])
    }

    @Test func missingOrLaterParentsMakeRootsSoCyclesCannotHideEntries() {
        var a = entry(1)
        let b = entry(2, parent: a.id)
        a.parentID = b.id
        let orphan = entry(3, parent: UUID())
        let tree = NetworkTree.build([a, b, orphan])
        #expect(tree.map(\.id) == [a.id, orphan.id])
        #expect(tree[0].children?.map(\.id) == [b.id])
    }

    @Test func deepChainsDoNotRecurse() {
        var entries: [NetworkEntry] = [entry(1)]
        for index in 2...20_000 { entries.append(entry(index, parent: entries[index - 2].id)) }
        let tree = NetworkTree.build(entries)
        #expect(tree.count == (20_000 + NetworkTree.maxDepth - 1) / NetworkTree.maxDepth)
        var depth = 0
        var node: NetworkTreeNode? = tree.first
        while let current = node {
            depth += 1
            node = current.children?.first
        }
        #expect(depth == NetworkTree.maxDepth)
    }

    @Test func waterfallPlacesBarsOnASharedAxis() throws {
        let entries = [entry(1, start: 0, end: 0.5, state: .completed(status: 200)), entry(2, start: 1, end: 2, state: .completed(status: 204)),
                       entry(3, start: 1.5), entry(4, start: 1.8, state: .pending)]
        let layout = WaterfallLayout.compute(entries, now: Date(timeIntervalSince1970: 1_003))
        #expect(layout.origin == Date(timeIntervalSince1970: 1_000))
        #expect(layout.span >= 3)
        #expect(layout.bars[0].start == 0)
        #expect(layout.bars[1].start > layout.bars[0].start + layout.bars[0].length)
        #expect(layout.bars[2].length == 0)
        #expect(layout.bars[3].isOpen)
        #expect(layout.bars.allSatisfy { $0.start + $0.length <= 1.000_001 })
        #expect(layout.ticks().first == 0)
        #expect(WaterfallLayout.compute([], now: Date()).bars.isEmpty)
        // A request the renderer never reports does not stretch the axis forever.
        let stale = WaterfallLayout.compute(entries, now: Date(timeIntervalSince1970: 1_000 + 86_400))
        #expect(stale.span < WaterfallLayout.maximumOpenDuration * 1.2)
    }

    @Test func filtersByCategoryDeliveryAndWords() {
        let entries = [entry(1, category: .win, url: "https://dsp.example/win?price=1.2"),
                       entry(2, category: .impression, delivery: .network, url: "https://imp.example/i"),
                       entry(3, category: .creative, state: .blocked, delivery: .blocked, url: "https://cdn.example/x.js"),
                       entry(4, category: .content, state: .completed(status: 404), delivery: .network, url: "https://cdn.example/v.xml")]
        #expect(NetworkFilter().apply(entries).count == 4)
        #expect(NetworkFilter(categories: [.win, .impression]).apply(entries).map(\.sequence) == [1, 2])
        #expect(NetworkFilter(deliveries: [.blocked]).apply(entries).map(\.sequence) == [3])
        #expect(NetworkFilter(text: "CDN.example js").apply(entries).map(\.sequence) == [3])
        #expect(NetworkFilter(text: "404").apply(entries).map(\.sequence) == [4])
        #expect(NetworkFilter(failuresOnly: true).apply(entries).map(\.sequence) == [4])
    }

    @Test func clickThroughsOpenOnlyInRealModeWithTheSettingOn() {
        let url = "https://advertiser.example"
        #expect(!NetworkPreferences.shouldOpenInBrowser(url, mode: .simulated, settingEnabled: true, device: nil))
        #expect(!NetworkPreferences.shouldOpenInBrowser(url, mode: .real, settingEnabled: false, device: nil))
        #expect(NetworkPreferences.shouldOpenInBrowser(url, mode: .real, settingEnabled: true, device: nil))
        #expect(!NetworkPreferences.shouldOpenInBrowser("javascript:alert(1)", mode: .real, settingEnabled: true, device: nil))
        let tv = DeviceProfile(id: "tv", name: "TV", family: .ctv, screenWidth: 1920, screenHeight: 1080, scale: 1, os: "tvOS", osVersion: "18",
                               make: "Apple", model: "TV", userAgent: "AppleTV", openRTBDeviceType: 3, input: .remote, supportsClickThrough: false)
        #expect(!NetworkPreferences.shouldOpenInBrowser(url, mode: .real, settingEnabled: true, device: tv))
    }

    @Test func timeoutPreferenceDefaultsAndClamps() throws {
        let defaults = try #require(UserDefaults(suiteName: "ccinn-test-\(UUID().uuidString)"))
        #expect(NetworkPreferences.requestTimeout(in: defaults) == 15)
        defaults.set(30.0, forKey: NetworkPreferences.requestTimeoutKey)
        #expect(NetworkPreferences.requestTimeout(in: defaults) == 30)
        defaults.set(99_999.0, forKey: NetworkPreferences.requestTimeoutKey)
        #expect(NetworkPreferences.requestTimeout(in: defaults) == 300)
        #expect(!NetworkPreferences.opensClickThroughs(in: defaults))
    }
}

@MainActor
@Suite("HAR export")
struct HARExportTests {
    @Test func exportsAValidHAR12Document() async throws {
        let clock = ManualClock()
        let transport = FakeTransport(clock: clock, latency: 0.05)
        transport.redirect("https://t.example/imp?bid=b1&price=1.23", to: "https://hop.example/p")
        transport.respond("https://hop.example/p", headers: ["Content-Type": "text/plain"], body: "ok")
        let monitor = makeMonitor(transport: transport, clock: clock)
        let template = "https://t.example/imp?bid=${AUCTION_BID_ID}&price=${AUCTION_PRICE}"
        let simulated = TrackerRequest(category: .win, trigger: "win", source: "bid 0.0", template: template,
                                       url: "https://t.example/win?x=[UNKNOWN]", replacedMacros: ["${AUCTION_PRICE}"], unknownMacros: ["[UNKNOWN]"])
        monitor.dispatch(simulated, userAgent: deviceUA)
        monitor.mode = .real
        let real = TrackerRequest(category: .impression, trigger: "impression", source: "bid 0.0 › native", template: template,
                                  url: "https://t.example/imp?bid=b1&price=1.23", replacedMacros: ["${AUCTION_BID_ID}", "${AUCTION_PRICE}"])
        let realID = monitor.dispatch(real, userAgent: deviceUA)
        await monitor.waitUntilIdle()

        let data = monitor.harData()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try #require(json["log"] as? [String: Any])
        #expect(log["version"] as? String == "1.2")
        #expect((log["creator"] as? [String: Any])?["name"] as? String == "CcinnOpenRTB")
        let entries = try #require(log["entries"] as? [[String: Any]])
        #expect(entries.count == 3)

        for entry in entries {
            let timings = try #require(entry["timings"] as? [String: Double])
            let sum = ["blocked", "dns", "connect", "send", "wait", "receive"].compactMap { timings[$0] }.filter { $0 > 0 }.reduce(0, +)
            #expect(abs((entry["time"] as? Double ?? -1) - sum) < 0.001, "time must equal the sum of the timings")
            for key in ["send", "wait", "receive"] { #expect((timings[key] ?? -1) >= 0) }
            #expect((entry["startedDateTime"] as? String)?.contains("T") == true)
            let request = try #require(entry["request"] as? [String: Any])
            for key in ["method", "url", "httpVersion", "cookies", "headers", "queryString", "headersSize", "bodySize"] { #expect(request[key] != nil) }
            let response = try #require(entry["response"] as? [String: Any])
            for key in ["status", "statusText", "httpVersion", "cookies", "headers", "content", "redirectURL", "headersSize", "bodySize"] {
                #expect(response[key] != nil)
            }
            #expect(entry["cache"] != nil)
        }

        let first = try #require(entries.first?["_ccinn"] as? [String: Any])
        #expect(first["category"] as? String == "win")
        #expect(first["mode"] as? String == "simulated")
        #expect(first["delivery"] as? String == "simulated")
        #expect(first["template"] as? String == template)
        #expect((first["macros"] as? [String: [String]])?["unknown"] == ["[UNKNOWN]"])
        #expect((entries.first?["response"] as? [String: Any])?["status"] as? Int == 0)

        let second = try #require(entries[1]["_ccinn"] as? [String: Any])
        #expect(second["mode"] as? String == "real")
        #expect((entries[1]["response"] as? [String: Any])?["redirectURL"] as? String == "https://hop.example/p")
        let query = try #require((entries[1]["request"] as? [String: Any])?["queryString"] as? [[String: String]])
        #expect(query.map { $0["name"] ?? "" } == ["bid", "price"])
        let hop = try #require(entries[2]["_ccinn"] as? [String: Any])
        #expect(hop["parent"] as? String == realID.uuidString)
        let content = try #require((entries[2]["response"] as? [String: Any])?["content"] as? [String: Any])
        #expect(content["text"] as? String == "ok")
        #expect(content["mimeType"] as? String == "text/plain")
    }

    @Test func parentsOutsideTheExportAreOmitted() throws {
        let entry = NetworkEntry(parentID: UUID(), sequence: 1, category: .event, trigger: "t", source: "s", template: "u", url: "https://x/",
                                 state: .simulated)
        let data = try HARExporter.data(entries: [entry], creatorVersion: "1.0.0")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"parent\""))
        #expect(text.contains("\"version\" : \"1.0.0\""))
    }
}

@MainActor
@Suite("VAST fetcher")
struct MonitorVASTFetcherTests {
    @Test func fetchesThroughTheMonitorAndLinksTheChain() async throws {
        let transport = FakeTransport()
        transport.respond("https://a.example/wrapper.xml", headers: ["Content-Type": "application/xml; charset=iso-8859-1"],
                          data: "<VAST><AdTitle>Caf\u{E9}</AdTitle></VAST>".data(using: .isoLatin1) ?? Data())
        transport.respond("https://b.example/inline.xml", body: "\u{FEFF}<VAST version=\"3.0\"/>")
        let monitor = makeMonitor(transport: transport)
        monitor.mode = .simulated
        let root = monitor.recordNavigation(url: "https://x", trigger: "seed", source: "test", parentID: nil)
        let fetcher = MonitorVASTFetcher(monitor: monitor, userAgent: deviceUA, source: "bid 0.0 › VAST", rootParentID: root)

        let first = try await fetcher.fetchVAST("https://a.example/wrapper.xml", parentRequestID: nil)
        #expect(first.body == "<VAST><AdTitle>Café</AdTitle></VAST>")
        let second = try await fetcher.fetchVAST("https://b.example/inline.xml", parentRequestID: first.requestID)
        #expect(second.body == "<VAST version=\"3.0\"/>")

        let firstID = try #require(first.requestID)
        let secondID = try #require(second.requestID)
        let firstEntry = try #require(monitor.entry(id: firstID))
        let secondEntry = try #require(monitor.entry(id: secondID))
        #expect(firstEntry.parentID == root)
        #expect(secondEntry.parentID == first.requestID)
        #expect(firstEntry.category == .content)
        #expect(firstEntry.trigger == "VAST wrapper")
        #expect(transport.requests.allSatisfy { $0.headers["User-Agent"] == deviceUA })
    }

    @Test func offlineDataChainsNeedNoNetwork() async throws {
        let transport = FailingTransport()
        let monitor = makeMonitor(transport: transport)
        let fetcher = MonitorVASTFetcher(monitor: monitor, userAgent: deviceUA)
        let inline = DataURL.make(Data("<VAST version=\"4.2\"><Ad/></VAST>".utf8), mimeType: "text/xml")
        let result = try await fetcher.fetchVAST(inline, parentRequestID: nil)
        #expect(result.body.hasPrefix("<VAST version=\"4.2\">"))
        #expect(transport.callCount == 0)
    }

    @Test func failuresPropagate() async {
        let monitor = makeMonitor(transport: FakeTransport())
        let fetcher = MonitorVASTFetcher(monitor: monitor, userAgent: deviceUA)
        await #expect(throws: NetworkMonitorError.self) { _ = try await fetcher.fetchVAST("https://nowhere.example/x", parentRequestID: nil) }
    }
}
