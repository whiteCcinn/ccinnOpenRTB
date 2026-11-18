import CcinnOpenRTBKit
import Foundation
import Network
import RTBKit
import Testing
@testable import CcinnOpenRTB

// Shared pieces of the end-to-end acceptance suites: test copies of the built-in samples pointed at a loopback server,
// the loopback HTTP server itself, a session wired to the real kit, and a driver that plays each sample through the real
// renderer models exactly as the renderers report to the host.

// MARK: - Test copies of the samples

/// The built-in samples with every sample host (`tracker.example`, `advertiser.example`, `apps.example`) pointed at a
/// loopback server, inside base64 `data:` URLs too (wrapper chains, markup by reference), so a request that leaves the
/// process can only reach that server.
enum SampleCopies {
    static let sampleHosts = ["https://tracker.example", "https://advertiser.example", "https://apps.example"]

    static func pointing(_ sample: Sample, at base: String) throws -> Sample {
        var copy = sample
        copy.response = try pointing(sample.response, at: base)
        copy.request = try sample.request.map { try pointing($0, at: base) }
        return copy
    }

    /// `text` with the sample hosts replaced by `base` (`http://127.0.0.1:<port>`), recursively inside base64 `data:` URLs.
    static func pointing(_ text: String, at base: String) throws -> String {
        let expression = try NSRegularExpression(pattern: #"data:([A-Za-z0-9.+/-]+);base64,([A-Za-z0-9+/]+=*)"#)
        var result = text
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result), let typeRange = Range(match.range(at: 1), in: result),
                  let payloadRange = Range(match.range(at: 2), in: result),
                  let decoded = Data(base64Encoded: String(result[payloadRange])),
                  let inner = String(data: decoded, encoding: .utf8) else { continue }
            let rewritten = try pointing(inner, at: base)
            result.replaceSubrange(whole, with: "data:\(result[typeRange]);base64,\(Data(rewritten.utf8).base64EncodedString())")
        }
        for host in sampleHosts {
            result = result.replacingOccurrences(of: host, with: base)
        }
        return result
    }
}

// MARK: - Loopback HTTP server

/// A loopback HTTP/1.1 server: it counts connections, records each request once (method, target, headers) and answers
/// `200` with a 1×1 GIF (an empty script for `.js` paths), or `302 Found` to `/landed/…` for targets under `/redirect/`. `Connection: close` on every
/// response, so one connection is one request.
final class EchoServer: @unchecked Sendable {
    struct Received: Sendable, Equatable {
        var method: String
        /// Path and query exactly as sent.
        var target: String
        /// Lower-cased names.
        var headers: [String: String]
    }

    private static let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00,
                                   0x00, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
                                   0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B])
    private static let headTerminator = Data("\r\n\r\n".utf8)
    private static let maxHeadBytes = 256 * 1024

    private let listener: NWListener
    private let queue = DispatchQueue(label: "acceptance.echo")
    private let lock = NSLock()
    private var connections = 0
    private var received: [Received] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    }

    var connectionCount: Int { lock.withLock { connections } }
    var requests: [Received] { lock.withLock { received } }

    /// Starts listening; the port, or `nil` when the listener never got one.
    func start() async -> UInt16? {
        listener.start(queue: queue)
        for _ in 0..<500 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        lock.withLock { connections += 1 }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Self.headTerminator) {
                respond(to: buffer[buffer.startIndex..<end.lowerBound], on: connection)
            } else if isComplete || error != nil || buffer.count > Self.maxHeadBytes {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count >= 2 else {
            connection.cancel()
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(requestLine[1])
        lock.withLock { received.append(Received(method: String(requestLine[0]), target: target, headers: headers)) }
        var response: Data
        if target.hasPrefix("/redirect/") {
            let location = "/landed/" + target.dropFirst("/redirect/".count)
            response = Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        } else if (target.split(separator: "?").first ?? "").hasSuffix(".js") {
            let script = Data("/* ccinn acceptance */".utf8)
            response = Data(("HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nContent-Length: \(script.count)\r\n"
                    + "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n").utf8)
            response.append(script)
        } else {
            response = Data(("HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: \(Self.gif.count)\r\n"
                    + "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n").utf8)
            response.append(Self.gif)
        }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - A session on the real kit

/// A session wired like the app's (live kit services, a real `NetworkMonitor`), with a manual clock for the viewability
/// timers, a recording browser and "Open click-throughs" off.
@MainActor
struct AcceptanceSession {
    let session: AdSession
    let monitor: NetworkMonitor
    let clock: ManualSessionClock
    let browser: RecordingBrowser

    init(transport: any HTTPTransport) {
        monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        clock = ManualSessionClock()
        browser = RecordingBrowser()
        session = AdSession(services: .live, monitor: monitor, clock: clock, browser: browser, opensClickThroughs: { false }, parseDebounce: .zero)
    }

    /// The device the acceptance runs use for `sample`: the CTV pod on Apple TV 4K, everything else on iPhone 17 Pro.
    static func deviceID(for sample: Sample) -> String {
        sample.id.contains("ctv") ? "apple-tv-4k" : "iphone-17-pro"
    }

    /// Loads `sample` on its device and renders it; returns once the render settled.
    func render(_ sample: Sample) async throws {
        session.device = try #require(DeviceCatalog.device(id: Self.deviceID(for: sample)))
        await session.load(sample, render: true)
        await waitUntilSettled()
    }

    func waitUntilSettled() async {
        for _ in 0..<5_000 {
            if case .preparing = session.phase { try? await Task.sleep(for: .milliseconds(2)) } else { break }
        }
        await monitor.waitUntilIdle()
    }

    /// Enters Real mode the way the user does: the confirmation lists the bid's tracker hosts, then it is confirmed.
    /// Returns the hosts the confirmation listed.
    @discardableResult
    func confirmRealMode() throws -> [String] {
        session.requestRealMode()
        let confirmation = try #require(session.realModeConfirmation, "Real mode needs the confirmation")
        #expect(session.mode == .simulated, "asking is not switching")
        session.confirmRealMode(confirmation)
        #expect(session.mode == .real)
        return confirmation.summary.hosts.map(\.name)
    }
}

// MARK: - The renderer contract, driven through the real renderer models

/// Plays the ad on the device through the real renderer models (`HTMLAdModel` with its web view, `ImageBannerModel`,
/// `NativeAdModel`, `VASTPlayerModel` on a scripted engine), so every lifecycle event reaches the session exactly as the
/// renderers report it: the full lifecycle, one user action at a time.
@MainActor
final class LifecycleDriver {
    /// One user action and the triggers its requests carry.
    struct Action: Equatable {
        var name: String
        var firstSequence: Int
        var lastSequence: Int
    }

    let harness: AcceptanceSession
    private(set) var actions: [Action] = []
    private var html: HTMLAdModel?
    private var player: VASTPlayerModel?

    init(_ harness: AcceptanceSession) {
        self.harness = harness
    }

    private var session: AdSession { harness.session }
    private var host: any AdRenderingHost { session.rendererHost }

    func teardown() {
        html?.teardown()
        player?.teardown()
    }

    /// The whole lifecycle of the ad on the device. Returns `false` when there is no ad to play.
    func run() async throws -> Bool {
        guard let request = session.renderRequest else { return false }
        switch request.candidate.markup {
        case let .html(markup):
            try await playHTML(markup, request: request)
        case let .image(banner):
            try await playImage(banner, request: request)
        case .native:
            try await playNative(request)
        case .vast:
            try await playVAST(request)
        case .none:
            return false
        }
        await harness.monitor.waitUntilIdle()
        return true
    }

    /// Records the sequences one user action produced.
    private func action(_ name: String, _ body: () async throws -> Void) async rethrows {
        let before = harness.monitor.liveEntries.last?.sequence ?? 0
        try await body()
        await harness.monitor.waitUntilIdle()
        let after = harness.monitor.liveEntries.last?.sequence ?? 0
        if after > before { actions.append(Action(name: name, firstSequence: before + 1, lastSequence: after)) }
    }

    /// Display viewability: the ad stays in view past the MRC display thresholds.
    private func settleDisplayViewability() {
        harness.clock.set(harness.clock.now() + 1.2)
        session.settleViewability()
    }

    private func playHTML(_ markup: String, request: RenderRequest) async throws {
        let model = HTMLAdModel(host: host)
        html = model
        model.load(markup: markup, request: request, blocksNetwork: HTMLAdModel.blocksNetwork(harness.monitor))
        let rendered = await Wait.until(timeout: .seconds(20)) { self.session.hasFired(.rendered) }
        #expect(rendered, "the HTML creative never reported .rendered")
        // The creative's own requests (blocked in Simulated mode) are reported asynchronously by the page.
        try await Task.sleep(for: .milliseconds(300))
        settleDisplayViewability()
        // A click: the HTML renderer reports `.click(assetID: nil)`, then the destination only the creative knows.
        await action("click") {
            host.report(.click(assetID: nil))
            host.navigate(to: Self.landing(in: markup) ?? "https://advertiser.example/landing", trigger: "mraid.open", source: request.sourceRoot + " › adm")
        }
        await action("close") { host.report(.closed) }
    }

    private func playImage(_ banner: ImageBanner, request: RenderRequest) async throws {
        let model = ImageBannerModel(host: host)
        await model.load(banner, request: request)
        #expect(session.hasFired(.rendered), "the image banner never reported .rendered")
        settleDisplayViewability()
        await action("click") { model.click(banner, request: request) }
        await action("close") { model.close() }
    }

    private func playNative(_ request: RenderRequest) async throws {
        let ad = try #require(request.native)
        let model = NativeAdModel(ad: ad, request: request, host: host)
        await model.loadAssets()
        await model.loadImages()
        model.appeared()
        #expect(session.hasFired(.rendered), "the Native ad never reported .rendered")
        settleDisplayViewability()
        let assetWithLink = model.ad.assets.first { $0.link != nil }?.id
        await action("asset click") { model.click(assetID: assetWithLink ?? model.ad.assets.first?.id) }
        await action("ad click") { model.click(assetID: nil) }
        await action("privacy") { model.openPrivacy() }
        await action("close") { model.close() }
    }

    private func playVAST(_ request: RenderRequest) async throws {
        let vast = try #require(request.vast)
        let audioOnly = request.candidate.format == .audio
        let configuration = VASTPlayerConfiguration(request: request, role: .ad(audioOnly: audioOnly), playerSize: request.adSize)
        let engine = FakeEngine()
        let model = VASTPlayerModel(vast: vast, configuration: configuration, host: host, engine: engine, chooseMedia: VASTMediaSelector.choose)
        player = model
        model.setVisibleFraction(request.visibleFraction)
        model.start()
        let items = VASTPodPlan.items(for: vast, source: request.sourceRoot + " › VAST")
        var loads = 0
        for item in items {
            // An ad without playable media (VPAID only → 901, none → 403) is reported by the player and skipped.
            guard case .play = VASTMediaSelector.choose(item.mediaFiles, playerWidth: 1280, playerHeight: 720, audioOnly: audioOnly) else {
                let reported = await Wait.until(timeout: .seconds(10)) {
                    self.harness.monitor.liveEntries.contains { $0.category == .error && $0.trigger.contains("error") }
                }
                #expect(reported, "ad \(item.adIndex + 1): the player never reported its media error")
                continue
            }
            let loaded = await Wait.until(timeout: .seconds(60)) { engine.loaded.count > loads }
            #expect(loaded, "ad \(item.adIndex + 1): the player never loaded its media")
            guard loaded else { continue }
            loads = engine.loaded.count
            let duration = item.declaredDuration ?? 15
            engine.send(.ready(duration: duration))
            let start = harness.clock.now()
            var playhead = 0.0
            var clicked = false
            while playhead <= duration {
                engine.send(.tick(playhead))
                harness.clock.set(start + playhead)
                session.settleViewability()
                if !clicked, playhead >= duration / 2 {
                    clicked = true
                    if let choice = CompanionPicker.pick(item.companions, fitting: nil) {
                        await action("companion view") { model.companionDidAppear(choice, adIndex: item.adIndex) }
                        await action("companion click") {
                            model.companionClicked(choice, adIndex: item.adIndex, url: choice.playerOpensClickThrough ? nil : choice.companion.clickThrough)
                        }
                    }
                    await action("video click") { model.clickThrough() }
                }
                playhead += 0.25
            }
            engine.send(.ended)
        }
        await harness.monitor.waitUntilIdle()
    }

    /// The first `https://advertiser.example/…` (or rewritten) landing URL a creative names, for its own navigation.
    private static func landing(in markup: String) -> String? {
        guard let range = markup.range(of: #"https?://[^"'\s\\]+/landing[^"'\s\\]*"#, options: .regularExpression) else { return nil }
        return String(markup[range])
    }
}

// MARK: - Network relationship audit (decisions.md, "Network relationships")

/// Checks the monitor's entries for one rendered sample against the binding relationship rules and the lifecycle order.
/// Each check returns human-readable violations (empty: the rule holds).
@MainActor
struct NetworkAudit {
    let entries: [NetworkEntry]
    let candidate: AdCandidate
    let vast: ResolvedVAST?
    let markupRequestID: UUID?

    private var byID: [UUID: NetworkEntry] { Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }

    private static let trackerCategories: Set<TrackerCategory> = [.win, .billing, .loss, .impression, .viewability, .event, .click, .error,
                                                                  .verification]

    /// Every parent exists and was recorded before its child.
    func parentsPrecedeChildren() -> [String] {
        entries.compactMap { entry in
            guard let parentID = entry.parentID else { return nil }
            guard let parent = byID[parentID] else { return "#\(entry.sequence) \(entry.category) has an unknown parent" }
            return parent.sequence < entry.sequence ? nil : "#\(entry.sequence) \(entry.category) precedes its parent #\(parent.sequence)"
        }
    }

    /// A tracker never parents a navigation, or anything but its own redirect hops — unless it delivered the markup (a
    /// win notice returning `adm`: the markup's URLs are its children) or it is a script tracker whose injection made the
    /// load (its child).
    func trackersParentOnlyTheirRedirects() -> [String] {
        entries.compactMap { entry in
            guard let parentID = entry.parentID, let parent = byID[parentID], Self.trackerCategories.contains(parent.category),
                  parent.id != markupRequestID else { return nil }
            if entry.redirectLocation != nil, entry.category == parent.category { return nil }
            if parent.isScript, entry.category == .creative { return nil }
            return "#\(entry.sequence) \(entry.category) '\(entry.trigger)' hangs under tracker #\(parent.sequence) \(parent.category)"
        }
    }

    /// URLs of the pasted bid response (nurl/purl, burl, lurl, AdCOM `display.event`, the AdCOM banner link) have no parent.
    func responseLevelURLsAreRoots() -> [String] {
        let responseTemplates = Set([candidate.winURL, candidate.billingURL, candidate.lossURL].compactMap { $0 }
            + candidate.adcomEvents.compactMap(\.url) + Self.bannerLinkURLs(candidate))
        return entries.compactMap { entry in
            guard entry.redirectLocation == nil, responseTemplates.contains(entry.template), let parentID = entry.parentID,
                  byID[parentID]?.isScript != true else { return nil }
            return "#\(entry.sequence) \(entry.category) \(entry.template) is in the bid response but has a parent"
        }
    }

    private static func bannerLinkURLs(_ candidate: AdCandidate) -> [String] {
        guard case let .image(banner) = candidate.markup, let link = banner.link else { return [] }
        return [link.url] + link.clickTrackers
    }

    /// Requests whose URL is inside markup delivered by nurl / `display.curl` hang under that request; inline markup's
    /// have no parent. VAST requests are checked by `vastRequestsHangUnderTheirHops`.
    func markupURLsHangUnderTheMarkupRequest() -> [String] {
        let responseTemplates = Set([candidate.winURL, candidate.billingURL, candidate.lossURL].compactMap { $0 }
            + candidate.adcomEvents.compactMap(\.url) + Self.bannerLinkURLs(candidate))
        let vastTemplates = vastTemplatesByHop().keys
        return entries.compactMap { entry in
            guard entry.redirectLocation == nil, entry.id != markupRequestID, !responseTemplates.contains(entry.template),
                  !Set(vastTemplates).contains(entry.template), !entry.source.contains("VAST"),
                  !(entry.parentID.flatMap { byID[$0] }?.isScript ?? false) else { return nil }
            switch entry.category {
            case .creative, .navigation, .impression, .viewability, .click, .event, .content:
                return entry.parentID == markupRequestID ? nil
                    : "#\(entry.sequence) \(entry.category) \(entry.url.prefix(80)) parent \(String(describing: entry.parentID)) ≠ markup request"
            default:
                return nil
            }
        }
    }

    /// Each VAST request hangs under the hop that delivered the document its URL is in (the inline adm: no parent).
    func vastRequestsHangUnderTheirHops() -> [String] {
        let templates = vastTemplatesByHop()
        return entries.compactMap { entry in
            guard entry.redirectLocation == nil, let hops = templates[entry.template], hops.count == 1, let hop = hops.first,
                  let vast, vast.chain.indices.contains(hop), entry.category != .navigation else { return nil }
            let expected = vast.chain[hop].requestID
            return entry.parentID == expected ? nil
                : "#\(entry.sequence) \(entry.category) \(entry.template.prefix(80)) parent \(String(describing: entry.parentID)) ≠ hop \(hop)"
        }
    }

    /// Template → the hops whose document text contains it (inline adm for hop 0, decoded `data:` URLs for the others).
    private func vastTemplatesByHop() -> [String: Set<Int>] {
        guard let vast else { return [:] }
        var documents: [Int: String] = [:]
        for (index, hop) in vast.chain.enumerated() {
            if let url = hop.url, let decoded = DataURL.decode(url) {
                documents[index] = String(decoding: decoded.data, as: UTF8.self)
            } else if hop.url == nil, case let .vast(.xml(xml)) = candidate.markup {
                documents[index] = xml
            }
        }
        var result: [String: Set<Int>] = [:]
        for entry in entries where entry.redirectLocation == nil {
            for (index, text) in documents where text.contains(entry.template) {
                result[entry.template, default: []].insert(index)
            }
        }
        return result
    }

    /// The siblings of one user action share one trigger: a click's trackers and its navigation. (A click-through also
    /// pauses a playing video, a separate lifecycle event with its own trigger, `pause`.)
    func oneTriggerPerAction(_ actions: [LifecycleDriver.Action]) -> [String] {
        actions.compactMap { action in
            let produced = entries.filter {
                $0.sequence >= action.firstSequence && $0.sequence <= action.lastSequence && $0.redirectLocation == nil
                    && ($0.category == .click || $0.category == .navigation)
            }
            let triggers = Set(produced.map(\.trigger))
            return triggers.count <= 1 ? nil : "\(action.name) produced \(triggers.count) triggers: \(triggers.sorted())"
        }
    }

    /// The lifecycle order: won → billing (rendered) → impressions → quartiles → complete, by the first entry of each.
    func lifecycleOrder() -> [String] {
        func first(_ predicate: (NetworkEntry) -> Bool) -> Int? { entries.first(where: predicate)?.sequence }
        let won = first { $0.category == .win }
        let billing = first { $0.category == .billing }
        let impression = first { $0.category == .impression }
        let start = first { $0.trigger.hasPrefix("VAST start") }
        let quartiles = ["firstQuartile", "midpoint", "thirdQuartile", "complete"].map { name in first { $0.trigger.hasPrefix("VAST \(name)") } }
        let ordered: [(String, Int?)] = [("won", won), ("billing", billing), ("impression", impression), ("start", start),
                                         ("firstQuartile", quartiles[0]), ("midpoint", quartiles[1]), ("thirdQuartile", quartiles[2]),
                                         ("complete", quartiles[3])]
        let present = ordered.compactMap { name, sequence in sequence.map { (name, $0) } }
        return zip(present, present.dropFirst()).compactMap { earlier, later in
            earlier.1 < later.1 ? nil : "\(earlier.0) #\(earlier.1) is not before \(later.0) #\(later.1)"
        }
    }

    func all(_ actions: [LifecycleDriver.Action]) -> [String] {
        parentsPrecedeChildren() + trackersParentOnlyTheirRedirects() + responseLevelURLsAreRoots() + markupURLsHangUnderTheMarkupRequest()
            + vastRequestsHangUnderTheirHops() + oneTriggerPerAction(actions) + lifecycleOrder()
    }
}

extension NetworkEntry {
    /// A one-line dump for failure messages and evidence.
    var dumpLine: String {
        let parent = parentID.map { String($0.uuidString.prefix(8)) } ?? "—"
        return "#\(sequence) [\(String(id.uuidString.prefix(8))) ← \(parent)] \(category) \(delivery.rawValue) '\(trigger)' \(url.prefix(140))"
    }
}
