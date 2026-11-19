import CcinnOpenRTBKit
import Foundation
import Observation
import RTBKit

/// The Prebid tab of one main window: a publisher page running official Prebid.js on the simulated device — the version
/// (the newest at least two weeks old by default), the bidders the version offers, ad units with params, consent — an
/// auction whose every request goes through the window's network gate, and its bids shown on the device by the
/// simulator.
@MainActor
@Observable
final class PrebidModel {
    enum Phase: Equatable, Sendable {
        case idle
        case preparing
        case running
        case done
        case failed(String)
    }

    struct TimelineEntry: Identifiable, Equatable, Sendable {
        let id: Int
        /// Milliseconds since the auction started.
        var at: Int
        var type: String
        var summary: String
    }

    struct Sync: Hashable, Sendable {
        var kind: String
        var url: String
    }

    var setup: PrebidSetup
    private(set) var versions: [String] = []
    private(set) var defaultVersion: String?
    private(set) var catalog: [String: PrebidBidder] = [:]
    private(set) var phase: Phase = .idle
    private(set) var timeline: [TimelineEntry] = []
    private(set) var bids: [PrebidBid] = []
    private(set) var syncs: [Sync] = []
    private(set) var warnings: [String] = []
    /// `pbjs.version` the page reported.
    private(set) var loadedVersion: String?
    /// The window's Sync tab: its cookie jar goes with the page's requests, and a sync can be handed to it.
    @ObservationIgnored weak var syncModel: SyncModel?

    @ObservationIgnored let host: PrebidHost
    @ObservationIgnored private let target: any ClientSimulatorTarget
    @ObservationIgnored private let library: PrebidLibrary
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?

    /// Prebid's public AppNexus test placement: an ad unit that bids, to start from.
    static let starterAdUnit = PrebidAdUnit(code: "div-banner-1", mediaType: .banner, sizes: [AdSize(width: 300, height: 250), AdSize(width: 320, height: 50)],
                                            bids: [PrebidBidderParams(bidder: "appnexus", params: #"{"placementId": 13144370}"#)])

    init(target: any ClientSimulatorTarget, library: PrebidLibrary? = nil, now: @escaping @MainActor () -> Date = { Date() }) {
        self.target = target
        self.now = now
        let library = library ?? PrebidLibrary(monitor: { [unowned target] in target.monitor },
                                               userAgent: { [unowned target] in SyncBrowser.default(for: target.device).userAgent(for: target.device) })
        self.library = library
        let bridge = PrebidNetworkBridge(monitor: { [unowned target] in target.monitor },
                                         userAgent: { [unowned target] in SyncBrowser.default(for: target.device).userAgent(for: target.device) })
        host = PrebidHost(library: library, bridge: bridge, userAgent: SyncBrowser.default(for: target.device).userAgent(for: target.device))
        var initial = PrebidSetup(version: "")
        initial.adUnits = [Self.starterAdUnit]
        setup = initial
        bridge.onRequest = { [weak self] kind, url, status in
            self?.note("request", "\(kind) \(URLText.hostAndPath(url).prefix(80))" + (status.map { " → \($0)" } ?? " → failed"))
        }
        host.onEvent = { [weak self] type, payload in self?.handle(type: type, payload: payload) }
    }

    // MARK: Versions and bidders

    /// Loads the versions (the default: the newest stable release at least two weeks old) and the chosen version's bidders.
    func prepare() async {
        phase = .preparing
        do {
            let dates = try await library.releaseDates()
            versions = PrebidVersions.stableVersions(dates)
            defaultVersion = PrebidVersions.defaultVersion(releasedAt: dates, now: now())
            if setup.version.isEmpty || !versions.contains(setup.version) { setup.version = defaultVersion ?? versions.first ?? "" }
            await loadCatalog()
        } catch {
            phase = .failed("The Prebid.js versions could not be read: " + ClientModel.message(for: error))
        }
    }

    /// Another version: a running auction stops (its events belong to the old page) and the version's bidders load.
    func choose(version: String) {
        guard version != setup.version else { return }
        stop()
        setup.version = version
        catalogTask?.cancel()
        phase = .preparing
        catalogTask = Task { [weak self] in await self?.loadCatalog() }
    }

    /// The bidders of `setup.version`. An answer for a version no longer chosen is dropped.
    func loadCatalog() async {
        let version = setup.version
        guard !version.isEmpty else { return }
        phase = .preparing
        do {
            let bidders = try await library.catalog(version: version)
            guard version == setup.version else { return }
            catalog = Dictionary(bidders.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
            phase = .idle
        } catch {
            guard version == setup.version else { return }
            catalog = [:]
            phase = .failed("The bidders of Prebid.js \(version) could not be read: " + ClientModel.message(for: error))
        }
    }

    // MARK: Auction

    /// The simulated device as the page sees it (its screen, viewport, platform).
    var device: PrebidDevice {
        PrebidDevice(device: target.device, userAgent: userAgent)
    }

    /// The User-Agent of the device's browser: the page's and its requests'.
    private var userAgent: String {
        SyncBrowser.default(for: target.device).userAgent(for: target.device)
    }

    /// Loads the page with the setup and runs `requestBids`. Problems in the setup stop it before anything loads.
    func runAuction() {
        let html: String
        do {
            html = try PrebidPage.html(for: setup, catalog: catalog, distBase: library.distBase(version: setup.version), device: device)
        } catch {
            phase = .failed(error.problems.map(\.message).joined(separator: " "))
            return
        }
        guard let url = PrebidPage.pageURL(of: setup) else { return }
        generation &+= 1
        let token = generation
        timeline = []
        bids = []
        syncs = []
        warnings = []
        loadedVersion = nil
        startedAt = now()
        phase = .running
        note("page", "Prebid.js \(setup.version) on \(setup.pageURL)")
        let version = setup.version
        let userAgent = userAgent
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.host.load(html, at: url, version: version, userAgent: userAgent)
            } catch {
                guard token == self.generation, self.phase == .running else { return }
                self.watchdog?.cancel()
                self.phase = .failed(ClientModel.message(for: error))
            }
        }
        // The auction ends with bidsBack; a page that never gets there (a loader that failed) ends here.
        let limit = Duration.milliseconds(setup.timeoutMilliseconds) + .seconds(20)
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard let self, token == self.generation, self.phase == .running else { return }
            self.phase = .failed("The auction did not end: Prebid.js did not load or call back (see the log and the Network window).")
        }
    }

    func stop() {
        generation &+= 1
        watchdog?.cancel()
        host.stop()
        if phase == .running { phase = .idle }
    }

    /// Shows `bid` on the device, by the simulator's own path (an explicit Render: in Real mode its trackers are sent).
    func render(_ bid: PrebidBid) async {
        let response = PrebidBid.openRTBResponse(for: [bid], auctionID: "prebid-\(bid.adID.isEmpty ? UUID().uuidString : bid.adID)")
        _ = await target.loadExchange(request: "", response: response, device: nil, rendering: .always)
    }

    /// The sync goes to the Sync tab, on this page: the page's site decides which of its cookies are third party.
    func useInSyncTab(_ sync: Sync) {
        guard let syncModel else { return }
        syncModel.startURL = sync.url
        syncModel.publisherURL = setup.pageURL
    }

    // MARK: Events

    func handle(type: String, payload: String) {
        guard phase == .running || type == "sync" || type == "log" else { return }
        let value = try? JSONValue.parse(payload)
        switch type {
        case "ready":
            loadedVersion = Self.string(value, "version")
            note(type, "Prebid.js \(loadedVersion ?? "?") loaded")
        case "bidRequested":
            note(type, "\(Self.string(value, "bidderCode") ?? "?"): \(Self.count(value, "bids")) bid request(s)")
        case "bidResponse":
            if let bid = PrebidBid.parse(payload) {
                note(type, "\(bid.bidderCode) \(InputSummary.price(bid.cpm)) \(bid.currency)" + (bid.width.map { " \($0)×\(bid.height ?? 0)" } ?? "")
                    + " \(bid.mediaType ?? "") → \(bid.adUnitCode ?? "")")
            }
        case "noBid":
            note(type, "\(Self.string(value, "bidder") ?? Self.string(value, "bidderCode") ?? "?") → \(Self.string(value, "adUnitCode") ?? "")")
        case "bidTimeout":
            let bidders = Self.array(value).compactMap { Self.string($0, "bidder") }
            note(type, "timed out: " + Set(bidders).sorted().joined(separator: ", "))
        case "bidderDone":
            note(type, Self.string(value, "bidderCode") ?? "?")
        case "bidderError":
            note(type, String(payload.prefix(200)))
        case "auctionEnd", "auctionInit", "adRenderFailed":
            note(type, "")
        case "bidsBack":
            bids = PrebidBid.parseList(payload)
            note(type, "\(bids.count) bid(s)")
            watchdog?.cancel()
            phase = .done
        case "sync":
            if let kind = Self.string(value, "kind"), let url = Self.string(value, "url") {
                let sync = Sync(kind: kind, url: url)
                if !syncs.contains(sync) { syncs.append(sync) }
                note(type, "\(kind) \(URLText.hostAndPath(url).prefix(80))")
            }
        case "log":
            if let message = Self.string(value, "message") { warnings.append(String(message.prefix(500))) }
        case "scriptError":
            // A Prebid.js file that did not load or failed its integrity check: the loader gives up, so does the auction.
            let url = Self.string(value, "url") ?? "?"
            note(type, url)
            watchdog?.cancel()
            phase = .failed("Prebid.js did not load: \(URLText.hostAndPath(url).prefix(120)) — \(Self.string(value, "reason") ?? "it failed").")
        default:
            note(type, String(payload.prefix(120)))
        }
    }

    private func note(_ type: String, _ summary: String) {
        sequence += 1
        timeline.append(TimelineEntry(id: sequence, at: max(0, Int(now().timeIntervalSince(startedAt) * 1000)), type: type, summary: summary))
        if timeline.count > 2_000 { timeline.removeFirst(timeline.count - 2_000) }
    }

    private static func string(_ value: JSONValue?, _ key: String) -> String? {
        guard case let .object(members)? = value else { return nil }
        switch members[key] {
        case let .string(text)?: return text
        case let .int(number)?: return String(number)
        default: return nil
        }
    }

    private static func array(_ value: JSONValue?) -> [JSONValue] {
        if case let .array(elements)? = value { return elements }
        return []
    }

    private static func count(_ value: JSONValue?, _ key: String) -> Int {
        guard case let .object(members)? = value, case let .array(elements)? = members[key] else { return 0 }
        return elements.count
    }
}
