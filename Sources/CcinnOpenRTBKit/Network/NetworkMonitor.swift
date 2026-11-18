import Foundation
import Observation
import RTBKit

/// The session's network: dispatches trackers by mode, fetches content, records creative requests, and keeps the
/// ordered, related entries the Network window shows (design D9).
///
/// - Simulated mode never sends a tracker: `DispatchPolicy` is the only source of the `SendPermit` that the single
///   transport call site (`send(_:permit:)`) requires, and it issues none for Simulated-mode trackers. A tracker's
///   redirect chain re-checks the mode before every hop.
/// - Offline (`offline`) is Simulated tracking plus offline content: remote content is recorded and not sent
///   (`NetworkDelivery.offline`, `NetworkMonitorError.offline`); only `data:` and `ccinn-sample:` URLs load.
/// - Leaving Real mode cancels every tracker in flight at once (no further redirect hop is sent); going Offline cancels
///   every request in flight; `cancelInFlightTrackers(reason:)` does the first on demand (Render, Reset).
/// - `entries` is published coalesced (at most every `publishInterval`, 50 ms by default) so bursts do not thrash
///   SwiftUI. `flush()` publishes at once; `NetworkMonitor(publishInterval: .zero)` publishes synchronously (tests).
///   `entry(id:)` and `liveEntries` read the log directly.
/// - At most `capacity` entries (10,000) are kept, oldest first out.
@MainActor
@Observable
public final class NetworkMonitor {
    public static let defaultCapacity = 10_000
    public static let maxRedirects = 10
    /// Content (VAST, images, markup) larger than this fails.
    public nonisolated static let maxContentBytes = 32 << 20
    /// Tracker bodies are read up to this size and then truncated (the size read is still recorded).
    public static let maxTrackerBodyBytes = 1 << 20
    /// What an en-US iPhone sends.
    public nonisolated static let defaultAcceptLanguage = "en-US,en;q=0.9"
    /// The size of each byte-range request for progressive media.
    public nonisolated static let defaultMediaChunkBytes = 2 << 20

    /// Why trackers in flight are cancelled when the session leaves Real mode.
    public nonisolated static let simulatedCancellation = "switched to Simulated mode"
    /// Why every request in flight is cancelled when the session goes Offline.
    public nonisolated static let offlineCancellation = "the session went Offline"

    /// The published (coalesced) entries, in sequence order.
    public private(set) var entries: [NetworkEntry] = []

    /// Whether trackers are sent. Leaving `.real` cancels every tracker in flight; choosing `.real` leaves Offline.
    public var mode: TrackingMode {
        get { trackingMode }
        set {
            trackingMode = newValue
            if newValue == .real {
                isOffline = false
            } else {
                cancelInFlightTrackers(reason: Self.simulatedCancellation)
            }
        }
    }

    /// Offline: Simulated tracking plus offline content. Turning it on switches to Simulated mode, closes the creative's
    /// own network and cancels every request in flight; remote content is then recorded and not sent.
    public var offline: Bool {
        get { isOffline }
        set {
            guard newValue != isOffline else { return }
            isOffline = newValue
            guard newValue else { return }
            trackingMode = .simulated
            cancelLoads(reason: Self.offlineCancellation) { _ in true }
        }
    }

    /// Simulated mode: let the HTML creative load from the network for this session. Always `false` while Offline (the
    /// opt-in is kept for when Offline ends).
    public var allowCreativeNetwork: Bool {
        get { creativeNetworkOptIn && !isOffline }
        set { creativeNetworkOptIn = newValue }
    }
    /// Seconds allowed for each request hop (Settings ▸ Network ▸ Request timeout); used clamped to 0.1…300.
    public var requestTimeout: TimeInterval = 15
    /// `Accept-Language` of every request the monitor sends, set explicitly so the Mac's locale never leaks through
    /// CFNetwork's default. The simulated device's language when the session knows it; `defaultAcceptLanguage` otherwise.
    public var acceptLanguage: String = NetworkMonitor.defaultAcceptLanguage

    private var trackingMode: TrackingMode = .simulated
    private var isOffline = false
    private var creativeNetworkOptIn = false

    @ObservationIgnored private var log: NetworkLog
    @ObservationIgnored private var bodies = ResponseBodyStore()
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private let clock: any NetworkClock
    @ObservationIgnored private let samples: any SampleMediaProviding
    /// The files `data:` media is written to for the player, deleted when the render ends.
    @ObservationIgnored private let mediaFiles: MediaTemporaryFiles
    /// Routes remote media for the player through the monitor; created with the first remote media.
    @ObservationIgnored private var mediaRouterStorage: MediaRouter?
    /// The size of each byte-range request for progressive media (tests make it small).
    @ObservationIgnored var mediaChunkBytes = NetworkMonitor.defaultMediaChunkBytes
    @ObservationIgnored private let publishInterval: Duration
    @ObservationIgnored private var publishScheduled = false
    @ObservationIgnored private var dirty = false
    /// Incremented by `clear()`; in-flight work started under an older generation stops recording.
    @ObservationIgnored private var generation = 0
    /// Every load in progress (trackers and content), by root entry id.
    @ObservationIgnored private var activeLoads: [UUID: ActiveLoad] = [:]
    /// Loads cancelled while in flight, with the error they end with; their entries are already finished.
    @ObservationIgnored private var cancelledLoads: [UUID: NetworkMonitorError] = [:]
    /// Entries whose outcome the renderer reports (`finishRendererLoad`).
    @ObservationIgnored private var rendererLoads: Set<UUID> = []

    public convenience init(transport: any HTTPTransport = URLSessionTransport.shared, clock: any NetworkClock = SystemNetworkClock(),
                            samples: any SampleMediaProviding = SampleMedia.shared, publishInterval: Duration = .milliseconds(50),
                            capacity: Int = NetworkMonitor.defaultCapacity) {
        self.init(transport: transport, clock: clock, samples: samples, publishInterval: publishInterval, capacity: capacity,
                  mediaFiles: MediaTemporaryFiles())
    }

    init(transport: any HTTPTransport, clock: any NetworkClock = SystemNetworkClock(), samples: any SampleMediaProviding,
         publishInterval: Duration, capacity: Int = NetworkMonitor.defaultCapacity, mediaFiles: MediaTemporaryFiles) {
        self.transport = transport
        self.clock = clock
        self.samples = samples
        self.publishInterval = publishInterval
        self.mediaFiles = mediaFiles
        log = NetworkLog(capacity: capacity)
    }

    // MARK: Reading

    /// A live entry (not waiting for the next publish).
    public func entry(id: UUID) -> NetworkEntry? { log.entry(id) }

    /// All live entries (not waiting for the next publish).
    public var liveEntries: [NetworkEntry] { log.entries }

    /// The stored response body (≤ 512 KiB per entry, 32 MiB overall) for previews.
    public func responseBody(for id: UUID) -> Data? { bodies.body(for: id) }

    /// Requests the monitor is still loading (trackers and content).
    public var inFlightCount: Int { activeLoads.count }

    /// Publishes pending changes to `entries` now.
    public func flush() {
        publishScheduled = false
        guard dirty else { return }
        dirty = false
        entries = log.entries
    }

    /// Waits until every request in flight has finished (tests, export).
    public func waitUntilIdle() async {
        while let (id, load) = activeLoads.first {
            _ = await load.task.value
            if activeLoads[id]?.task == load.task { activeLoads[id] = nil }
        }
    }

    // MARK: Trackers

    /// Records a tracker; sends it in Real mode (with `userAgent`). Returns the entry id.
    @discardableResult
    public func dispatch(_ request: TrackerRequest, userAgent: String) -> UUID {
        var entry = NetworkEntry(id: request.id, parentID: request.parentID, sequence: 0, startedAt: clock.now(), category: request.category,
                                 trigger: request.trigger, source: request.source, template: request.template, url: request.url,
                                 state: .pending, replacedMacros: request.replacedMacros, unknownMacros: request.unknownMacros,
                                 isScript: request.isScript, sessionMode: mode)
        let destination = DispatchPolicy.Destination(url: request.url)
        switch DispatchPolicy.action(for: request.category, isScript: request.isScript, mode: mode, offline: offline, destination: destination) {
        case let .record(state, delivery, note):
            entry.state = state
            entry.delivery = delivery
            entry.note = note
            return append(entry).id
        case let .renderer(note):
            entry.delivery = .renderer
            entry.note = note
            entry.requestHeaders = requestHeaders(userAgent: userAgent)
            let stored = append(entry)
            rendererLoads.insert(stored.id)
            return stored.id
        case let .send(permit):
            entry.delivery = .network
            entry.requestHeaders = requestHeaders(userAgent: userAgent)
            let stored = append(entry)
            let isTracker = request.category.isTracker
            let limit = isTracker ? Self.maxTrackerBodyBytes : Self.maxContentBytes
            startLoad(stored, permit: permit, userAgent: userAgent, maxBodyBytes: limit, failOnTruncation: !isTracker)
            return stored.id
        }
    }

    // MARK: Content

    /// Fetches content needed to render (VAST wrappers, media, images, win-notice markup) in both modes. `data:` URLs are
    /// decoded and `ccinn-sample://` URLs served locally (still recorded). A tracker `category` (e.g. `.win` for
    /// win-notice markup) obeys the mode: in Simulated mode it is recorded and `notSentInSimulatedMode` is thrown.
    /// Offline, remote content is recorded and `offline` is thrown.
    public func fetchContent(_ url: String, category: TrackerCategory = .content, trigger: String, source: String, parentID: UUID?,
                             userAgent: String) async throws -> (data: Data, entryID: UUID) {
        var entry = NetworkEntry(parentID: parentID, sequence: 0, startedAt: clock.now(), category: category, trigger: trigger, source: source,
                                 template: url, url: url, state: .pending, sessionMode: mode)
        switch DispatchPolicy.action(for: category, isScript: false, mode: mode, offline: offline, destination: DispatchPolicy.Destination(url: url)) {
        case let .record(state, delivery, note):
            entry.state = state
            entry.delivery = delivery
            entry.note = note
            if delivery == .offline { entry.requestHeaders = requestHeaders(userAgent: userAgent) }
            let stored = append(entry)
            if delivery == .offline { throw NetworkMonitorError.offline(entryID: stored.id) }
            if category.isTracker { throw NetworkMonitorError.notSentInSimulatedMode(entryID: stored.id) }
            throw NetworkMonitorError.notFetchable(entryID: stored.id)
        case .renderer:
            entry.state = .simulated
            let stored = append(entry)
            throw NetworkMonitorError.notFetchable(entryID: stored.id)
        case let .send(permit):
            entry.delivery = .network
            entry.requestHeaders = requestHeaders(userAgent: userAgent)
            let stored = append(entry)
            let task = startLoad(stored, permit: permit, userAgent: userAgent, maxBodyBytes: Self.maxContentBytes, failOnTruncation: true)
            let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            return (try outcome.get().body, stored.id)
        }
    }

    /// Prepares media for a player (AVPlayer): `ccinn-sample://` becomes the generated local file and `data:` a temporary
    /// file (deleted when the render ends). `http(s)` media gets a private-scheme `playableURL` that only its
    /// `resourceLoader` answers: open it with `AVURLAsset` and `resourceLoader.attach(to:)`, then every byte the player
    /// needs (byte ranges, redirects, HLS playlists, keys and segments) is fetched by the monitor, through the dispatch
    /// policy, with the device's headers and no cookies, and recorded under the media entry. Report the player's outcome
    /// with `finishRendererLoad`. Offline, remote media is recorded and not prepared (`failure` is `offline`).
    public func prepareMedia(_ url: String, trigger: String, source: String, parentID: UUID?, userAgent: String) async -> PreparedMedia {
        var entry = NetworkEntry(parentID: parentID, sequence: 0, startedAt: clock.now(), category: .content, trigger: trigger, source: source,
                                 template: url, url: url, state: .pending, sessionMode: mode)
        let token = generation
        switch URLText.scheme(url) {
        case SampleURL.scheme?:
            entry.delivery = .local
            let stored = append(entry)
            guard let asset = SampleURL.parse(url) else {
                finish(stored.id, failure: .sampleUnavailable("unknown sample \(url.prefix(120))"), token: token)
                return PreparedMedia(entryID: stored.id, failure: .sampleUnavailable("unknown sample"))
            }
            do {
                let file = try await samples.fileURL(for: asset)
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
                finishLocal(stored.id, bytes: size, mimeType: asset.mimeType, note: Self.sampleNote, body: nil, token: token)
                return PreparedMedia(playableURL: file, entryID: stored.id)
            } catch {
                let failure = NetworkMonitorError.sampleUnavailable(error.localizedDescription)
                finish(stored.id, failure: failure, token: token)
                return PreparedMedia(entryID: stored.id, failure: failure)
            }
        case "data"?:
            entry.delivery = .local
            entry.template = Self.abbreviatedDataURL(url)
            entry.url = entry.template
            let stored = append(entry)
            guard let decoded = DataURL.decode(url) else {
                let failure = NetworkMonitorError.invalidURL("malformed data: URL")
                finish(stored.id, failure: failure, token: token)
                return PreparedMedia(entryID: stored.id, failure: failure)
            }
            do {
                let file = try await mediaFiles.write(decoded.data, mimeType: decoded.mimeType)
                finishLocal(stored.id, bytes: decoded.data.count, mimeType: decoded.mimeType, note: Self.dataURLNote, body: nil, token: token)
                return PreparedMedia(playableURL: file, entryID: stored.id)
            } catch {
                let failure = NetworkMonitorError.transport(error.localizedDescription)
                finish(stored.id, failure: failure, token: token)
                return PreparedMedia(entryID: stored.id, failure: failure)
            }
        case "http"?, "https"?:
            entry.requestHeaders = requestHeaders(userAgent: userAgent)
            if case let .record(state, delivery, note) = DispatchPolicy.action(for: .content, isScript: false, mode: mode, offline: offline) {
                entry.state = state
                entry.delivery = delivery
                entry.note = note
                let stored = append(entry)
                return PreparedMedia(entryID: stored.id, failure: delivery == .offline ? .offline(entryID: stored.id) : .notFetchable(entryID: stored.id))
            }
            entry.delivery = .network
            entry.note = MediaRouter.mediaNote
            let stored = append(entry)
            guard let remote = URLText.requestURL(url) else {
                let failure = NetworkMonitorError.invalidURL(url)
                finish(stored.id, failure: failure, token: token)
                return PreparedMedia(entryID: stored.id, failure: failure)
            }
            rendererLoads.insert(stored.id)
            let router = mediaRouterStorage ?? MediaRouter(monitor: self)
            mediaRouterStorage = router
            let loader = router.makeLoader(for: remote, media: MediaContext(entryID: stored.id, source: source, trigger: trigger, userAgent: userAgent))
            return PreparedMedia(playableURL: loader.url, entryID: stored.id, resourceLoader: loader)
        default:
            let stored = append(entry)
            let failure = NetworkMonitorError.unsupportedScheme(URLText.scheme(url) ?? "")
            finish(stored.id, failure: failure, token: token)
            return PreparedMedia(entryID: stored.id, failure: failure)
        }
    }

    /// One request the player's remote media needs (a byte range, an HLS playlist, key or segment), decided by the
    /// dispatch policy like any content and recorded as a child of `part.parentID`. Returns the root entry and the final
    /// response. Cancelled when the caller is (the player cancelled), by Offline and by `clear()`.
    func fetchMediaPart(_ part: MediaPartRequest) async -> (entryID: UUID, result: Result<LoadedResponse, NetworkMonitorError>) {
        let url = part.url.absoluteString
        var headers: [String: String] = [:]
        if let range = part.range { headers["Range"] = range.header }
        var entry = NetworkEntry(parentID: part.parentID, sequence: 0, startedAt: clock.now(), category: .content, trigger: part.trigger,
                                 source: part.source, template: url, url: url, state: .pending,
                                 requestHeaders: requestHeaders(userAgent: part.userAgent).merging(headers) { _, part in part }, sessionMode: mode)
        switch DispatchPolicy.action(for: .content, isScript: false, mode: mode, offline: offline, destination: DispatchPolicy.Destination(url: url)) {
        case let .record(state, delivery, note):
            entry.state = state
            entry.delivery = delivery
            entry.note = note
            let stored = append(entry)
            return (stored.id, .failure(delivery == .offline ? .offline(entryID: stored.id) : .notFetchable(entryID: stored.id)))
        case .renderer:
            let stored = append(entry)
            return (stored.id, .failure(.notFetchable(entryID: stored.id)))
        case let .send(permit):
            entry.delivery = .network
            let stored = append(entry)
            let task = startLoad(stored, permit: permit, userAgent: part.userAgent, headers: headers, maxBodyBytes: part.maxBodyBytes,
                                 failOnTruncation: false)
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            return (stored.id, result)
        }
    }

    /// Changes the trigger of a media request once its response says what it is (an HLS playlist).
    func relabel(_ id: UUID, trigger: String) {
        update(id) { $0.trigger = trigger }
    }

    /// Reports the outcome of a load the renderer performed itself: player media from `prepareMedia`, a creative request
    /// recorded as not blocked, or a Real-mode script tracker. Ignored for any other entry, and only the first report
    /// counts.
    public func finishRendererLoad(_ id: UUID, status: Int? = nil, error: String? = nil, responseBytes: Int? = nil, mimeType: String? = nil) {
        guard rendererLoads.remove(id) != nil else { return }
        let now = clock.now()
        update(id) { entry in
            entry.finishedAt = now
            entry.state = error.map { .failed(String($0.prefix(500))) } ?? .completed(status: max(0, status ?? 0))
            if let responseBytes { entry.responseBytes = max(0, responseBytes) }
            if let mimeType { entry.mimeType = mimeType }
        }
    }

    // MARK: Creative and navigation

    /// Records a request the HTML creative made (or tried to make).
    @discardableResult
    public func recordCreativeRequest(url: String, kind: String, blocked: Bool, parentID: UUID?) -> UUID {
        let stored = append(NetworkEntry(parentID: parentID, sequence: 0, startedAt: clock.now(), category: .creative, trigger: kind,
                                         source: "creative", template: url, url: url, state: blocked ? .blocked : .pending,
                                         delivery: blocked ? .blocked : .renderer, sessionMode: mode,
                                         note: blocked ? "Blocked by the Simulated-mode sandbox" : "Loaded by the web view"))
        if !blocked { rendererLoads.insert(stored.id) }
        return stored.id
    }

    /// Records a click-through navigation (never followed inside the simulator). `openedInBrowser`: the app opened it in
    /// the default browser (Real mode with "Open click-throughs in browser" on).
    @discardableResult
    public func recordNavigation(url: String, trigger: String, source: String, parentID: UUID?, openedInBrowser: Bool = false) -> UUID {
        append(NetworkEntry(parentID: parentID, sequence: 0, startedAt: clock.now(), category: .navigation, trigger: trigger, source: source,
                            template: url, url: url, state: .simulated, delivery: openedInBrowser ? .browser : .simulated, sessionMode: mode,
                            note: openedInBrowser ? "Opened in the default browser" : DispatchPolicy.navigationNote)).id
    }

    // MARK: Session

    /// Cancels every tracker in flight (not content): its entry is finished at once as cancelled with `reason`, and no
    /// further redirect hop is sent. Leaving Real mode does this with `simulatedCancellation`; the session also calls it
    /// when a render ends (Render, Reset, a new generation).
    public func cancelInFlightTrackers(reason: String) {
        cancelLoads(reason: reason) { $0.isTracker }
    }

    /// The session's render ended (Render, Reset, a new generation): what the monitor prepared for it is released: the
    /// temporary files of its `data:` media, and the routes of its remote media (their loaders and proxy routes answer
    /// nothing more, and their requests in flight are cancelled). Call it before the next render prepares its media.
    public func endRender() {
        mediaFiles.removeAll()
        mediaRouterStorage?.invalidate()
    }

    /// Empties the log and restarts the sequence; requests in flight stop following redirects and are not recorded.
    /// Ends the render too (`endRender`).
    public func clear() {
        endRender()
        generation &+= 1
        for load in activeLoads.values { load.task.cancel() }
        activeLoads.removeAll()
        cancelledLoads.removeAll()
        rendererLoads.removeAll()
        log.removeAll()
        bodies.removeAll()
        dirty = true
        flush()
    }

    /// HAR 1.2 export of the current entries.
    public func harData() -> Data {
        let snapshot = harSnapshot()
        return (try? HARExporter.data(entries: snapshot.entries, bodies: snapshot.bodies)) ?? Data()
    }

    /// The entries and stored bodies, to encode HAR off the main actor with `HARExporter.data`.
    public func harSnapshot() -> (entries: [NetworkEntry], bodies: [UUID: Data]) {
        let entries = log.entries
        return (entries, bodies.bodies(for: entries.map(\.id)))
    }

    // MARK: Loading

    /// Starts `load` in its own task, registered in `activeLoads` so a mode switch, Offline or `clear()` can cancel it.
    @discardableResult
    private func startLoad(_ root: NetworkEntry, permit: SendPermit, userAgent: String, headers: [String: String] = [:], maxBodyBytes: Int,
                           failOnTruncation: Bool) -> Task<Result<LoadedResponse, NetworkMonitorError>, Never> {
        // Inherits the main actor: the body cannot start before the registration below.
        let task = Task { [weak self] () -> Result<LoadedResponse, NetworkMonitorError> in
            guard let self else { return .failure(.cleared) }
            return await self.load(root, permit: permit, userAgent: userAgent, headers: headers, maxBodyBytes: maxBodyBytes,
                                   failOnTruncation: failOnTruncation)
        }
        activeLoads[root.id] = ActiveLoad(task: task, isTracker: root.category.isTracker, currentEntryID: root.id)
        return task
    }

    /// Cancels the matching loads, and the load stops without recording anything more. A hop already handed to the
    /// transport is finished at once as cancelled; one not sent yet is recorded as not sent (Simulated, or Offline).
    private func cancelLoads(reason: String, where matches: (ActiveLoad) -> Bool) {
        let now = clock.now()
        for (id, load) in activeLoads where matches(load) {
            activeLoads[id] = nil
            load.task.cancel()
            guard load.isSending else {
                cancelledLoads[id] = markNotSent(load.currentEntryID, isTracker: load.isTracker, reason: reason)
                continue
            }
            let error = NetworkMonitorError.cancelled(reason)
            cancelledLoads[id] = error
            update(load.currentEntryID) { entry in
                guard entry.state == .pending else { return }
                entry.finishedAt = now
                entry.state = .failed(error.errorDescription ?? reason)
            }
        }
    }

    /// Loads `root` and follows redirects by hand: one recorded child entry per hop, at most `maxRedirects`, loops
    /// refused. The dispatch policy is asked again, against the current mode and Offline, right before every hop is
    /// sent, so a tracker is never sent after a switch to Simulated mode, not even its first hop. `headers` are added to
    /// the monitor's own (e.g. `Range`).
    private func load(_ root: NetworkEntry, permit _: SendPermit, userAgent: String, headers extraHeaders: [String: String], maxBodyBytes: Int,
                      failOnTruncation: Bool) async -> Result<LoadedResponse, NetworkMonitorError> {
        defer {
            activeLoads[root.id] = nil
            cancelledLoads[root.id] = nil
        }
        let token = generation
        var currentID = root.id
        var currentURL = root.url
        var visited: Set<String> = []
        var hops = 0

        while true {
            switch URLText.scheme(currentURL) {
            case "data"?:
                return loadDataURL(currentURL, entryID: currentID, maxBodyBytes: maxBodyBytes, token: token)
            case SampleURL.scheme?:
                return await loadSample(currentURL, entryID: currentID, token: token)
            case "http"?, "https"?:
                break
            default:
                let error = NetworkMonitorError.unsupportedScheme(URLText.scheme(currentURL) ?? "")
                finish(currentID, failure: error, token: token)
                return .failure(error)
            }
            guard let requestURL = URLText.requestURL(currentURL) else {
                let error = NetworkMonitorError.invalidURL(currentURL)
                finish(currentID, failure: error, token: token)
                return .failure(error)
            }
            guard token == generation else { return .failure(.cleared) }
            if let cancelled = cancelledLoads[root.id] { return .failure(cancelled) }
            guard let permit = DispatchPolicy.permit(for: root.category, isScript: root.isScript, mode: mode, offline: offline) else {
                return .failure(markNotSent(currentID, isTracker: root.category.isTracker, reason: Self.simulatedCancellation))
            }
            visited.insert(requestURL.absoluteString)

            let headers = requestHeaders(userAgent: userAgent).merging(extraHeaders) { _, extra in extra }
            let request = HTTPRequest(url: requestURL, headers: headers, timeout: Self.clampedTimeout(requestTimeout), maxBodyBytes: maxBodyBytes)
            update(currentID) { $0.requestHeaders = headers }
            activeLoads[root.id]?.isSending = true
            let response: HTTPResponse
            do {
                response = try await send(request, permit: permit)
            } catch {
                // A cancelled load's entry is already finished, with its reason.
                if let cancelled = cancelledLoads[root.id] { return .failure(cancelled) }
                let failure = Self.monitorError(error)
                finish(currentID, failure: failure, token: token)
                return .failure(token == generation ? failure : .cleared)
            }
            guard token == generation else { return .failure(.cleared) }
            if let cancelled = cancelledLoads[root.id] { return .failure(cancelled) }
            activeLoads[root.id]?.isSending = false

            record(response, for: currentID, maxBodyBytes: maxBodyBytes)

            if Self.isRedirect(response.status), let location = response.location {
                let next = URL(string: location, relativeTo: requestURL)?.absoluteURL ?? URLText.requestURL(location)
                let nextURL = next?.absoluteString ?? location
                let nextScheme = URLText.scheme(nextURL)
                var hop = NetworkEntry(parentID: root.id, sequence: 0, startedAt: clock.now(), category: root.category, trigger: root.trigger,
                                       source: root.source + " › redirect \(hops + 1)", template: location, url: nextURL, state: .pending,
                                       isScript: root.isScript, requestHeaders: requestHeaders(userAgent: userAgent),
                                       redirectLocation: location, delivery: .network, sessionMode: mode)
                let stop: NetworkMonitorError? = if next == nil {
                    .invalidURL(location)
                } else if hops >= Self.maxRedirects {
                    .tooManyRedirects(limit: Self.maxRedirects)
                } else if visited.contains(nextURL) {
                    .redirectLoop(nextURL)
                } else if nextScheme != "http", nextScheme != "https" {
                    .redirectNotFollowed(nextURL)
                } else {
                    nil
                }
                if let stop {
                    hop.state = .failed(stop.errorDescription ?? "Not followed")
                    hop.delivery = .simulated
                    hop.requestHeaders = [:]
                    hop.finishedAt = hop.startedAt
                    hop.note = "Not sent"
                    append(hop)
                    return .failure(stop)
                }
                hops += 1
                hop.note = "Redirect hop \(hops)"
                hop.requestHeaders = requestHeaders(userAgent: userAgent).merging(extraHeaders) { _, extra in extra }
                currentID = append(hop).id
                activeLoads[root.id]?.currentEntryID = currentID
                currentURL = nextURL
                continue
            }

            if response.truncated, failOnTruncation {
                let error = NetworkMonitorError.tooLarge(limit: maxBodyBytes)
                update(currentID) { $0.state = .failed(error.errorDescription ?? "Too large") }
                return .failure(error)
            }
            guard (200..<300).contains(response.status) else { return .failure(.httpStatus(response.status, entryID: currentID)) }
            return .success(LoadedResponse(body: response.body, status: response.status, headers: response.headers, url: requestURL,
                                           entryID: currentID, truncated: response.truncated))
        }
    }

    /// Records a hop that will not be sent, because the mode or Offline changed (or the session cancelled trackers)
    /// before it went out: Offline content as offline, anything else as simulated.
    private func markNotSent(_ id: UUID, isTracker: Bool, reason: String) -> NetworkMonitorError {
        if offline, !isTracker {
            update(id) { entry in
                entry.state = .blocked
                entry.delivery = .offline
                entry.requestHeadersAsSent = false
                entry.note = DispatchPolicy.offlineNote
            }
            return .offline(entryID: id)
        }
        update(id) { entry in
            entry.state = .simulated
            entry.delivery = .simulated
            entry.requestHeaders = [:]
            entry.requestHeadersAsSent = false
            entry.note = "Not sent: \(reason)"
        }
        return .notSentInSimulatedMode(entryID: id)
    }

    /// The only place a request reaches the transport. `permit` is the dispatch policy's proof that it may be sent.
    private func send(_ request: HTTPRequest, permit: SendPermit) async throws -> HTTPResponse {
        _ = permit
        let transport = transport
        let timeout = request.timeout
        return try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
            group.addTask { try await transport.perform(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw NetworkMonitorError.timedOut(seconds: timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw NetworkMonitorError.timedOut(seconds: timeout) }
            return first
        }
    }

    private func record(_ response: HTTPResponse, for id: UUID, maxBodyBytes: Int) {
        let finishedAt = clock.now()
        update(id) { entry in
            entry.finishedAt = finishedAt
            entry.state = .completed(status: response.status)
            entry.responseHeaders = response.headers
            entry.responseBytes = response.body.count
            entry.mimeType = response.mimeType
            entry.timings = response.timings
            if let sent = response.sentHeaders {
                entry.requestHeaders = sent
                entry.requestHeadersAsSent = true
            }
            if response.truncated {
                let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBodyBytes), countStyle: .binary)
                entry.note = Self.joined(entry.note, "Body truncated at \(limit)")
            }
        }
        bodies.store(response.body, for: id)
    }

    private func loadDataURL(_ url: String, entryID: UUID, maxBodyBytes: Int, token: Int) -> Result<LoadedResponse, NetworkMonitorError> {
        update(entryID) { entry in
            entry.delivery = .local
            entry.requestHeaders = [:]
            entry.url = Self.abbreviatedDataURL(entry.url)
            entry.template = Self.abbreviatedDataURL(entry.template)
        }
        guard let decoded = DataURL.decode(url) else {
            let error = NetworkMonitorError.invalidURL("malformed data: URL")
            finish(entryID, failure: error, token: token)
            return .failure(error)
        }
        guard decoded.data.count <= maxBodyBytes else {
            let error = NetworkMonitorError.tooLarge(limit: maxBodyBytes)
            finish(entryID, failure: error, token: token)
            return .failure(error)
        }
        finishLocal(entryID, bytes: decoded.data.count, mimeType: decoded.mimeType, note: Self.dataURLNote, body: decoded.data, token: token)
        return .success(LoadedResponse(body: decoded.data, status: 200, headers: ["Content-Type": decoded.mimeType], url: nil, entryID: entryID))
    }

    private func loadSample(_ url: String, entryID: UUID, token: Int) async -> Result<LoadedResponse, NetworkMonitorError> {
        update(entryID) { entry in
            entry.delivery = .local
            entry.requestHeaders = [:]
        }
        guard let asset = SampleURL.parse(url) else {
            let error = NetworkMonitorError.sampleUnavailable("unknown sample \(url.prefix(120))")
            finish(entryID, failure: error, token: token)
            return .failure(error)
        }
        do {
            let file = try await samples.fileURL(for: asset)
            let data = try await Self.readFile(file, limit: Self.maxContentBytes)
            finishLocal(entryID, bytes: data.count, mimeType: asset.mimeType, note: Self.sampleNote, body: data, token: token)
            return .success(LoadedResponse(body: data, status: 200, headers: ["Content-Type": asset.mimeType], url: nil, entryID: entryID))
        } catch {
            let failure = (error as? NetworkMonitorError) ?? .sampleUnavailable(error.localizedDescription)
            finish(entryID, failure: failure, token: token)
            return .failure(failure)
        }
    }

    // MARK: Recording

    @discardableResult
    private func append(_ entry: NetworkEntry) -> NetworkEntry {
        let stored = log.append(entry)
        didChange()
        return stored
    }

    private func update(_ id: UUID, _ change: (inout NetworkEntry) -> Void) {
        if log.update(id, change) { didChange() }
    }

    private func finish(_ id: UUID, failure: NetworkMonitorError, token: Int) {
        guard token == generation else { return }
        let now = clock.now()
        update(id) { entry in
            entry.finishedAt = now
            entry.state = .failed(failure.errorDescription ?? "Failed")
        }
    }

    private func finishLocal(_ id: UUID, bytes: Int?, mimeType: String, note: String, body: Data?, token: Int) {
        guard token == generation else { return }
        let now = clock.now()
        update(id) { entry in
            entry.finishedAt = now
            entry.state = .completed(status: 200)
            entry.delivery = .local
            entry.responseBytes = bytes
            entry.mimeType = mimeType
            entry.responseHeaders = ["Content-Type": mimeType]
            entry.note = note
        }
        if let body { bodies.store(body, for: id) }
    }

    private func didChange() {
        dirty = true
        guard publishInterval > .zero else {
            flush()
            return
        }
        guard !publishScheduled else { return }
        publishScheduled = true
        let interval = publishInterval
        Task { [weak self] in
            try? await Task.sleep(for: interval)
            self?.flush()
        }
    }

    // MARK: Helpers

    nonisolated static let sampleNote = "Local sample (generated on first use)"
    nonisolated static let dataURLNote = "data: URL decoded locally"

    /// The headers the monitor sets on a request (the HTTP stack adds `Host`, `Accept-Encoding` and `Connection`).
    func requestHeaders(userAgent: String) -> [String: String] {
        Self.requestHeaders(userAgent: userAgent, language: acceptLanguage)
    }

    nonisolated static func requestHeaders(userAgent: String, language: String) -> [String: String] {
        var headers = ["Accept": "*/*"]
        if let agent = headerValue(userAgent) { headers["User-Agent"] = agent }
        headers["Accept-Language"] = headerValue(language) ?? defaultAcceptLanguage
        return headers
    }

    /// `value` trimmed, or `nil` when empty or when it could split the header (CR, LF).
    nonisolated static func headerValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0 == "\r" || $0 == "\n" }) else { return nil }
        return trimmed
    }

    nonisolated static func isRedirect(_ status: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(status)
    }

    nonisolated static func clampedTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 15 }
        return min(max(value, 0.1), 300)
    }

    nonisolated static func monitorError(_ error: any Error) -> NetworkMonitorError {
        if let error = error as? NetworkMonitorError { return error }
        if error is CancellationError { return .transport("Cancelled") }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return .transport("Timed out")
            case .cancelled: return .transport("Cancelled")
            default: return .transport(error.localizedDescription)
            }
        }
        return .transport(error.localizedDescription)
    }

    nonisolated static func joined(_ note: String?, _ addition: String) -> String {
        guard let note, !note.isEmpty else { return addition }
        return note + " · " + addition
    }

    /// `data:` URLs can be megabytes; the log keeps the header and the first characters.
    nonisolated static func abbreviatedDataURL(_ url: String) -> String {
        guard url.utf8.count > 256 else { return url }
        return String(url.prefix(200)) + "…(\(url.utf8.count) bytes)"
    }

    /// Reads a file off the main actor, refusing anything above `limit`.
    nonisolated static func readFile(_ url: URL, limit: Int) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= limit else { throw NetworkMonitorError.tooLarge(limit: limit) }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }

}

/// What a load produced: the response of its final hop.
struct LoadedResponse: Sendable {
    var body: Data
    var status: Int
    var headers: [String: String]
    /// The URL that answered (after redirects); `nil` when served locally.
    var url: URL?
    /// The entry of the final hop.
    var entryID: UUID
    /// The body was cut at the request's `maxBodyBytes`.
    var truncated = false
}

/// One load in progress.
struct ActiveLoad {
    let task: Task<Result<LoadedResponse, NetworkMonitorError>, Never>
    let isTracker: Bool
    /// The current hop (the root, then each redirect hop).
    var currentEntryID: UUID
    /// The current hop has been handed to the transport.
    var isSending = false
}
