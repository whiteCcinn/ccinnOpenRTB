import CcinnOpenRTBKit
import CoreGraphics
import Foundation
import Observation
import RTBKit

/// One main window's simulator session (design D7, D9, D10): the pasted input, the selected bid, the simulated device
/// and placement, the render lifecycle and its trackers, viewability timers and the tracking mode. Renderers report
/// through `AdRenderingHost`.
///
/// Invariants (adversarially tested in `AdSessionTests`):
/// - Every session starts in Simulated mode; Real mode is only entered through `confirmRealMode(_:)` with the
///   confirmation that listed the tracker hosts.
/// - Each fire-once event fires at most once per render (`LifecycleGate`); win and loss exclude each other.
/// - `render()`, `reset()` and `lose(reason:)` start a new generation: work and timers of the previous one never record.
/// - The shell never synthesises `.rendered` for VAST: the player reports it at the first frame of ad 0.
/// - Renderers talk to `rendererHost`, a per-generation proxy: a renderer of an earlier render can never report into a
///   later one.
/// - A different device or placement is a different impression: Simulated mode renders again, Real mode removes the ad
///   (nothing is sent without an explicit Render).
@MainActor
@Observable
final class AdSession: AdRenderingHost {
    static let lifecycleLogCapacity = 500
    static let consoleCapacity = 1_000
    static let defaultParseDebounce: Duration = .milliseconds(250)

    // MARK: Dependencies

    let monitor: NetworkMonitor
    @ObservationIgnored let services: AdKitServices
    @ObservationIgnored private let clock: any SessionClock
    @ObservationIgnored private let browser: any BrowserOpening
    @ObservationIgnored private let opensClickThroughs: @MainActor () -> Bool
    @ObservationIgnored var parseDebounce: Duration

    // MARK: Input

    /// The response (or bare markup / VAST URL) panel.
    var responseText = "" { didSet { inputChanged() } }
    /// The optional bid request panel.
    var requestText = "" { didSet { inputChanged() } }
    private(set) var parsed = ParsedInput(kind: .empty)
    private(set) var isParsing = false
    var selectedCandidateID: String? {
        didSet { if oldValue != selectedCandidateID { candidateSelectionChanged() } }
    }

    /// Native ad / VAST document of the selected bid, parsed for the inspector and the Real-mode host list.
    private(set) var inspectedNative: NativeAd?
    private(set) var inspectedVAST: VASTDocument?

    // MARK: Device and placement

    var device: DeviceProfile = DeviceCatalog.defaultDevice { didSet { if oldValue != device { deviceChanged() } } }
    var landscape = false { didSet { geometryChanged() } }
    /// Foldables: use the cover screen.
    var folded = false { didSet { geometryChanged() } }
    /// Dual-screen: the app (and the ad) spans both screens.
    var spanned = false { didSet { geometryChanged() } }
    var placement: Placement = .inlineBanner {
        willSet { placementWillChange(to: newValue) }
        didSet { placementChanged(from: oldValue) }
    }
    var bannerPosition: BannerPosition = .bottom
    var zoom: ZoomSetting = .fit
    /// The magnification the canvas applies (Fit resolves to a number); the zoom commands step from it.
    var canvasMagnification = 1.0
    /// The viewability slider for every placement except in-feed (where the feed's scroll position decides).
    var visibility: Double = 1 { didSet { visibilityInputsChanged() } }
    /// The in-feed app's scroll position in points.
    var feedOffset: CGFloat = 0 { didSet { visibilityInputsChanged() } }

    // MARK: Macros and mode

    var macros = MacroSettings()
    /// Set while the Real-mode confirmation sheet is shown.
    private(set) var realModeConfirmation: RealModeConfirmation?

    // MARK: Render state

    private(set) var phase: RenderPhase = .idle
    private(set) var prepared: PreparedAd?
    /// Incremented by every render, reset and loss; renderers restart on change.
    private(set) var generation = 0
    /// Which replay of its auction the current play is (0: the first play, or nothing played); see `AuctionReplays`.
    private(set) var replay = 0
    @ObservationIgnored private var replays = AuctionReplays()
    /// The monitor's last sequence number when the current render started: later entries are this render's.
    @ObservationIgnored private var renderStartSequence = 0
    /// The auction of the current play (its `AuctionReplays` key).
    @ObservationIgnored private var playedAuction: String?
    /// Issues found while rendering (VAST resolution), appended to the input's issues.
    private(set) var renderIssues: [ValidationIssue] = []
    private(set) var lifecycleLog: [LifecycleLogEntry] = []
    private(set) var console: [ConsoleLine] = []
    /// Latest playback state per pod ad (`[ADPLAYHEAD]`, manual controls).
    private(set) var playback: [Int: PlaybackStatus] = [:]
    /// The pod ad playing most recently.
    private(set) var currentAdIndex = 0
    /// Real-mode script trackers (Native `jstracker`, `eventtrackers` / AdCOM events with method 2) for the renderer to run
    /// once each and report with `monitor.finishRendererLoad` (host requirement). Simulated mode records them and never
    /// lists them; a new render starts an empty list.
    private(set) var scriptTrackers: [ScriptTracker] = []
    /// The Native video asset's VAST, resolved through `resolveVAST(_:)`.
    private(set) var nativeVideoVAST: ResolvedVAST?
    /// What renderers of the current generation report through (see `RendererHostProxy`).
    private(set) var rendererHost: RendererHostProxy

    /// Observed: the Fire menu and the timer chips disable what already fired.
    private var gate = LifecycleGate()
    @ObservationIgnored private var viewability = ViewabilityController(kind: .none)
    @ObservationIgnored private var lastReportedFraction: Double?
    /// The input as it was when the current render started (auction id, request) — edits do not change its macros.
    @ObservationIgnored private var renderInput = ParsedInput(kind: .empty)
    @ObservationIgnored private var inputRevision = 0
    @ObservationIgnored private var parseTask: Task<Void, Never>?
    @ObservationIgnored private var inspectionTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var viewabilityTimer: Task<Void, Never>?
    @ObservationIgnored private var transactionID = UUID().uuidString
    /// The Native video VAST resolution of the current generation, shared by every caller asking for the same source.
    @ObservationIgnored private var nativeVideoResolution: (source: VASTSource, task: Task<ResolvedVAST, Never>)?
    /// A Native video tag resolved for the Real-mode confirmation (content, allowed in Simulated mode), so the sheet can
    /// list its trackers before the ad plays.
    @ObservationIgnored private var reviewedNativeVideo: (candidateID: String, revision: Int, source: VASTSource, resolved: ResolvedVAST?)?
    @ObservationIgnored private var logSequence = 0
    @ObservationIgnored private var consoleSequence = 0
    /// Set while a device change adjusts the placement (one context change, not two).
    @ObservationIgnored private var isAdjustingContext = false
    /// The placement suggested for the bid selected last (see `candidateSelectionChanged`).
    @ObservationIgnored private var lastSuggestedPlacement: Placement?

    init(services: AdKitServices = .live, monitor: NetworkMonitor? = nil, clock: any SessionClock = SystemSessionClock(),
         browser: (any BrowserOpening)? = nil, opensClickThroughs: (@MainActor () -> Bool)? = nil,
         parseDebounce: Duration = AdSession.defaultParseDebounce) {
        self.services = services
        let monitor = monitor ?? NetworkMonitor()
        self.monitor = monitor
        rendererHost = RendererHostProxy(generation: 0, monitor: monitor, device: DeviceCatalog.defaultDevice)
        self.clock = clock
        self.browser = browser ?? WorkspaceBrowser()
        self.opensClickThroughs = opensClickThroughs ?? { NetworkPreferences.opensClickThroughs(in: .standard) }
        self.parseDebounce = parseDebounce
        monitor.mode = .simulated
        rendererHost.session = self
    }

    // MARK: Derived

    var selectedCandidate: AdCandidate? {
        guard let selectedCandidateID else { return nil }
        return parsed.candidates.first { $0.id == selectedCandidateID }
    }

    /// Input issues plus the ones found while rendering, most severe first.
    var issues: [ValidationIssue] {
        (parsed.issues + renderIssues).enumerated()
            .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
            .map(\.element)
    }

    var layout: ScreenLayout { ScreenLayout(device: device, landscape: landscape, folded: folded, spanned: spanned) }

    /// The candidate the simulator sizes the ad slot for: the rendered one, else the selection.
    var slotCandidate: AdCandidate? { prepared?.candidate ?? selectedCandidate }

    var adSize: CGSize {
        let candidate = slotCandidate
        return AdSizing.adSize(bidSize: candidate?.size, format: candidate?.format ?? .banner, placement: placement, layout: layout)
    }

    var feedGeometry: FeedGeometry {
        FeedGeometry(layout: layout, adSize: adSize, captioned: slotCandidate?.format != .native)
    }

    /// 0…1 of the ad in view: the feed's scroll position for in-feed, else the viewability slider.
    var visibleFraction: Double {
        placement == .inFeed ? feedGeometry.visibleFraction(offset: feedOffset) : min(1, max(0, visibility))
    }

    /// The slider: sets the in-feed scroll position or the visibility directly.
    func setVisibleFraction(_ fraction: Double) {
        if placement == .inFeed {
            feedOffset = feedGeometry.offset(forVisibleFraction: fraction)
        } else {
            visibility = fraction.isFinite ? min(1, max(0, fraction)) : 1
        }
    }

    /// Scrolls the mock feed by `delta` points (positive: content moves down, towards the top of the feed).
    func scrollFeed(by delta: CGFloat) {
        guard placement == .inFeed, delta.isFinite else { return }
        feedOffset = feedGeometry.clamped(feedOffset - delta)
    }

    /// What the renderer draws; `nil` unless an ad is on the device.
    var renderRequest: RenderRequest? {
        guard phase == .ready, let prepared else { return nil }
        var candidate = prepared.candidate
        if let deviceMarkup = prepared.deviceMarkup { candidate.markup = deviceMarkup }
        return RenderRequest(candidate: candidate, native: prepared.native, vast: prepared.vast, device: device, placement: placement,
                             landscape: landscape, spanned: spanned, folded: folded, adSize: adSize, visibleFraction: visibleFraction,
                             generation: generation, markupRequestID: prepared.markupEntryID,
                             publisherAppBundle: renderInput.request?.appBundle, replay: replay)
    }

    /// The selected bid differs from the one on the device (the response was edited or another bid picked).
    var renderIsStale: Bool {
        guard let prepared, phase == .ready else { return false }
        guard let selected = selectedCandidate else { return true }
        return selected.id != prepared.candidate.id
            || (prepared.markupEntryID == nil && selected.markup != prepared.candidate.markup)
            || selected.winURL != prepared.candidate.winURL || selected.billingURL != prepared.candidate.billingURL
    }

    var mode: TrackingMode { monitor.mode }

    /// The rendered ad is VAST (video or audio).
    var isVAST: Bool {
        if case .vast = prepared?.candidate.markup { return true }
        return false
    }

    // MARK: Input

    private func inputChanged() {
        inputRevision &+= 1
        parseTask?.cancel()
        isParsing = true
        let revision = inputRevision
        let delay = parseDebounce
        parseTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.parse(revision: revision)
        }
    }

    /// Parses now (launch arguments, samples, tests), skipping the typing debounce, and returns once the parse of the
    /// current text is applied. An edit while it runs (an editor echoing the change back, a keystroke) supersedes it, so
    /// the newest text is parsed again rather than leaving the input unparsed (bounded: a text that keeps changing is
    /// left to the debounced parse).
    func parseNow() async {
        for _ in 0..<Self.parseNowAttempts {
            parseTask?.cancel()
            let revision = inputRevision
            await parse(revision: revision)
            if revision == inputRevision { return }
        }
    }

    static let parseNowAttempts = 4

    private func parse(revision: Int) async {
        let text = responseText
        let request = requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : requestText
        let parseInput = services.parseInput
        let result = await Task.detached(priority: .userInitiated) { parseInput(text, request) }.value
        guard revision == inputRevision else { return }
        isParsing = false
        parsed = result
        if let selectedCandidateID, result.candidates.contains(where: { $0.id == selectedCandidateID }) {
            candidateSelectionChanged()
        } else {
            selectedCandidateID = result.candidates.first?.id
            if selectedCandidateID == nil { candidateSelectionChanged() }
        }
    }

    /// The placement follows the kind of bid selected (its format and size: a 320×480 banner is an interstitial, Native is
    /// in-feed, video full screen): it changes when the suggestion for the selected bid changes, or when the placement
    /// cannot show the format. A placement the user picked stands while they edit the same kind of bid.
    private func candidateSelectionChanged() {
        defer { refreshRealModeConfirmation() }
        if let candidate = selectedCandidate {
            let suggested = Placement.suggested(for: candidate.format, size: candidate.size, on: device)
            let kindChanged = suggested != lastSuggestedPlacement
            lastSuggestedPlacement = suggested
            if placement != suggested, kindChanged || !Self.placement(placement, suits: candidate.format) { placement = suggested }
        }
        inspect()
    }

    /// Whether the user's placement can show `format` sensibly (otherwise the suggestion replaces it).
    private static func placement(_ placement: Placement, suits format: AdFormat) -> Bool {
        switch (placement, format) {
        case (.ctvInstream, _): true
        case (.inlineBanner, .video), (.inlineBanner, .audio), (.inlineBanner, .native): false
        default: true
        }
    }

    /// Parses the selected bid's Native / inline VAST markup off the main actor for the inspector.
    private func inspect() {
        inspectionTask?.cancel()
        let candidate = selectedCandidate
        let hints = candidate.flatMap { nativeHints(for: $0) }
        let services = services
        let revision = inputRevision
        inspectionTask = Task { [weak self] in
            let (native, vast) = await Task.detached(priority: .utility) { () -> (NativeAd?, VASTDocument?) in
                switch candidate?.markup {
                case let .native(json)?: (services.parseNative(json, hints).ad, nil)
                case let .vast(.xml(xml))?: (nil, services.parseVAST(xml).document)
                default: (nil, nil)
                }
            }.value
            guard let self, !Task.isCancelled, revision == self.inputRevision, candidate?.id == self.selectedCandidateID else { return }
            self.inspectedNative = native
            self.inspectedVAST = vast
            // A confirmation shown before the markup was inspected is re-prompted with the complete host list.
            self.refreshRealModeConfirmation()
        }
    }

    private func nativeHints(for candidate: AdCandidate) -> NativeRequestHints? {
        guard let impressions = parsed.request?.impressions else { return nil }
        let impression = impressions.first { $0.id == candidate.impID } ?? (impressions.count == 1 ? impressions.first : nil)
        return impression?.nativeHints
    }

    /// Loads a built-in sample into the editors and renders its first bid.
    func load(_ sample: Sample, render shouldRender: Bool = true) async {
        responseText = sample.response
        requestText = sample.request ?? ""
        await parseNow()
        if shouldRender { render() }
    }

    // MARK: Device and placement

    private func deviceChanged() {
        isAdjustingContext = true
        if device.family != .foldable { folded = false }
        if device.family != .dualScreen { spanned = false }
        let candidate = selectedCandidate
        let compatible = placement.compatible(with: device, format: candidate?.format, size: candidate?.size)
        if compatible != placement { placement = compatible }
        isAdjustingContext = false
        geometryChanged()
        impressionContextChanged()
    }

    /// The in-view share carries over between the feed (a scroll position) and the other placements (the slider).
    private func placementWillChange(to newValue: Placement) {
        if placement == .inFeed, newValue != .inFeed { visibility = feedGeometry.visibleFraction(offset: feedOffset) }
    }

    private func placementChanged(from oldValue: Placement) {
        guard placement != oldValue else { return }
        if !Placement.available(on: device).contains(placement) {
            placement = placement.compatible(with: device, format: selectedCandidate?.format, size: selectedCandidate?.size)
            return
        }
        if placement == .inFeed { feedOffset = feedGeometry.offset(forVisibleFraction: visibility) }
        geometryChanged()
        if !isAdjustingContext { impressionContextChanged() }
    }

    /// The ad on the device belongs to the device and placement it was rendered for. Simulated mode renders the bid again
    /// (nothing leaves the machine); Real mode removes it, so real trackers only follow an explicit Render.
    private func impressionContextChanged() {
        switch phase {
        case .ready, .preparing, .needsRealMode:
            break
        case .idle, .noBid, .failed, .lost:
            return
        }
        if monitor.mode == .simulated, let rendered = prepared?.candidate.id ?? selectedCandidateID, rendered == selectedCandidateID {
            render()
        } else {
            reset()
        }
    }

    private func geometryChanged() {
        defer { refreshRealModeConfirmation() }
        if placement == .inFeed { feedOffset = feedGeometry.clamped(feedOffset) }
        visibilityInputsChanged()
    }

    private func visibilityInputsChanged() {
        let fraction = visibleFraction
        guard fraction != lastReportedFraction else { return }
        lastReportedFraction = fraction
        guard phase == .ready else { return }
        deliver(viewability.visibility(fraction, at: clock.now()), origin: "viewability")
        scheduleViewabilityTimer()
    }

    // MARK: Render lifecycle

    /// Renders the selected bid from scratch: a new generation, so every fire-once event can fire again.
    func render() {
        startGeneration()
        guard let candidate = selectedCandidate else {
            switch parsed.kind {
            case .bidResponse: phase = .noBid(reason: parsed.noBidReason)
            case let .invalid(reason): phase = .failed(reason)
            default: phase = .idle
            }
            return
        }
        let input = parsed
        renderInput = input
        let token = generation
        phase = .preparing("Preparing…")
        beginPlay(candidate, input: input)
        log("render bid \(candidate.id) on \(device.name)" + replaySuffix, origin: "simulator", outcome: .fired(requests: 0))
        renderTask = Task { [weak self] in await self?.prepare(candidate, input: input, token: token) }
    }

    /// Removes the ad and stops everything of the current render.
    func reset() {
        startGeneration()
        phase = .idle
        log("reset", origin: "simulator", outcome: .fired(requests: 0))
    }

    /// The bid lost the auction: a new generation without rendering, and the loss notice (`lurl`, `${AUCTION_LOSS}`).
    func lose(_ reason: LossReason) {
        guard let candidate = selectedCandidate else { return }
        startGeneration()
        macros.lossReason = reason  // the picker's default for the next Lose; the context carries it on this lurl only
        prepared = PreparedAd(candidate: candidate, native: nil, vast: nil, markupEntryID: nil, markupFromWinNotice: false)
        phase = .lost(reason)
        renderInput = parsed
        beginPlay(candidate, input: parsed)
        log("lose bid \(candidate.id) (\(reason.title))" + replaySuffix, origin: "simulator", outcome: .fired(requests: 0))
        deliver([.loss(reason: reason.code)], origin: "manual")
    }

    /// Why the last play's trackers in flight are cancelled when a new play (Render, Reset, Lose) starts.
    nonisolated static let playEndedCancellation = "a new render started"

    private func startGeneration() {
        renderTask?.cancel()
        viewabilityTimer?.cancel()
        // The last play ends here: its trackers still in flight are cancelled (no late hit, no further hop) and what the
        // monitor prepared for it (media routes, data: media files) is released before the next render prepares its own.
        monitor.cancelInFlightTrackers(reason: Self.playEndedCancellation)
        monitor.endRender()
        renderStartSequence = monitor.liveEntries.last?.sequence ?? 0
        generation &+= 1
        prepared = nil
        renderIssues = []
        playback = [:]
        currentAdIndex = 0
        scriptTrackers = []
        nativeVideoVAST = nil
        nativeVideoResolution = nil
        rendererHost = RendererHostProxy(generation: generation, monitor: monitor, device: device)
        rendererHost.session = self
        gate = LifecycleGate()
        viewability = ViewabilityController(kind: .none)
        lastReportedFraction = nil
        transactionID = UUID().uuidString
        replay = 0
        playedAuction = nil
        refreshRealModeConfirmation()
    }

    /// The auction a bid belongs to: its `${AUCTION_ID}` (the response id or the macro override); without one, the bid of
    /// this input.
    private func auctionKey(_ candidate: AdCandidate, input: ParsedInput) -> (key: String, auctionID: String) {
        let auctionID = macroContext(for: candidate, input: input, adIndex: nil).auctionID?.trimmingCharacters(in: .whitespaces) ?? ""
        return auctionID.isEmpty ? ("bid \(candidate.id) of input \(inputRevision)", "bid \(candidate.id)") : ("auction " + auctionID, auctionID)
    }

    /// A render or a Lose plays the bid's auction: numbered as a replay after the first.
    private func beginPlay(_ candidate: AdCandidate, input: ParsedInput) {
        let auction = auctionKey(candidate, input: input).key
        playedAuction = auction
        replay = replays.play(auction)
    }

    private var replaySuffix: String { replay > 0 ? " · replay \(replay)" : "" }

    /// The root of the current play's network sources (`bid 0.0`, `bid 0.0 · replay N`).
    private func sourceRoot(_ candidate: AdCandidate) -> String {
        AuctionReplays.sourceRoot(candidateID: candidate.id, replay: replay)
    }

    private func prepare(_ original: AdCandidate, input: ParsedInput, token: Int) async {
        // Cancelling a task that has not started yet does not stop its body: a render superseded within the same turn
        // must not install its ad or fire its win into the next generation.
        guard token == generation, !Task.isCancelled else { return }
        var candidate = original
        var markupEntryID: UUID?
        var fromWinNotice = false
        // The provisional ad lets `.won` and the markup fetch use the session's tracking path.
        prepared = PreparedAd(candidate: candidate, native: nil, vast: nil, markupEntryID: nil, markupFromWinNotice: false)

        if case .none = candidate.markup {
            if let markupURL = candidate.markupURL {
                fireWonIfExchangeSendsIt(input: input)
                phase = .preparing("Fetching markup…")
                do {
                    let (data, entryID) = try await monitor.fetchContent(markupURL, category: .content, trigger: "markup (display.curl)",
                                                                         source: sourceRoot(candidate) + " › display.curl", parentID: nil,
                                                                         userAgent: device.userAgent)
                    guard token == generation else { return }
                    markupEntryID = entryID
                    candidate.markup = Self.markup(fromFetched: TextDecoding.string(from: data, charset: nil), format: candidate.format)
                } catch {
                    guard token == generation else { return }
                    phase = .failed("The markup could not be fetched from display.curl: \(error.localizedDescription)")
                    return
                }
            } else if let winURL = candidate.winURL {
                phase = .preparing("Fetching markup from the win notice…")
                let context = macroContext(for: candidate, input: input, adIndex: nil)
                // A bid-response URL: OpenRTB `${…}` only, as on the `.won` path (OpenRTB 2.6 §4.4).
                let expanded = services.expandOpenRTB(winURL, context)
                do {
                    let (data, entryID) = try await monitor.fetchContent(expanded.url, category: .win, trigger: "win (markup)",
                                                                         source: sourceRoot(candidate) + " › nurl", parentID: nil,
                                                                         userAgent: device.userAgent)
                    guard token == generation else { return }
                    markupEntryID = entryID
                    fromWinNotice = true
                    _ = gate.admit(.won)
                    candidate.markup = Self.markup(fromFetched: TextDecoding.string(from: data, charset: nil), format: candidate.format)
                } catch NetworkMonitorError.notSentInSimulatedMode {
                    guard token == generation else { return }
                    _ = gate.admit(.won)
                    phase = .needsRealMode("The markup is delivered by the win notice — switch to Real to fetch it.")
                    return
                } catch {
                    guard token == generation else { return }
                    phase = .failed("The win notice did not deliver markup: \(error.localizedDescription)")
                    return
                }
            } else {
                phase = .failed("The bid has no markup, no display.curl and no win notice.")
                return
            }
        } else {
            fireWonIfExchangeSendsIt(input: input)
        }

        // What the device receives: inline adm with the exchange's macros substituted; markup fetched after the win as is.
        let deviceMarkup = markupEntryID == nil ? substituteExchangeMacros(in: candidate.markup, candidate: candidate, input: input) : nil
        var native: NativeAd?
        var vast: ResolvedVAST?
        switch deviceMarkup ?? candidate.markup {
        case let .native(json):
            let hints = nativeHints(for: candidate)
            let parseNative = services.parseNative
            native = await Task.detached(priority: .userInitiated) { parseNative(json, hints).ad }.value
            guard token == generation else { return }
            if native == nil {
                phase = .failed("The Native markup could not be read; see the Inspector for its issues.")
                return
            }
        case let .vast(source):
            phase = .preparing("Resolving VAST…")
            let fetcher = MonitorVASTFetcher(monitor: monitor, userAgent: device.userAgent, source: sourceRoot(candidate) + " › VAST",
                                             rootParentID: markupEntryID, resolving: source)
            let resolved = await services.resolveVAST(source, fetcher, markupEntryID, macroContext(for: candidate, input: input, adIndex: nil))
            guard token == generation else { return }
            vast = resolved
            renderIssues = resolved.issues
        default:
            break
        }
        if markupEntryID != nil,
           let leftover = Self.unsubstitutedMacroIssue(in: candidate.markup, deliveredBy: fromWinNotice ? "nurl" : "display.curl") {
            renderIssues.append(leftover)
        }

        prepared = PreparedAd(candidate: candidate, native: native, vast: vast, markupEntryID: markupEntryID, markupFromWinNotice: fromWinNotice,
                              deviceMarkup: deviceMarkup)
        viewability = ViewabilityController(kind: Self.viewabilityKind(markup: candidate.markup, format: candidate.format))
        lastReportedFraction = visibleFraction
        _ = viewability.visibility(visibleFraction, at: clock.now())
        phase = .ready
        if let vast { resolutionFollowUps(vast, candidate: candidate, input: input, source: sourceRoot(candidate) + " › VAST") }
    }

    /// The exchange's substitution of its OpenRTB `${…}` auction macros in the bid's inline `adm` — HTML, Native JSON or
    /// VAST XML — before the device gets it (OpenRTB 2.6 §4.4; OpenRTB 3.0 likewise for `${OPENRTB_*}`). VAST `[…]` macros
    /// are the player's and stay until a tracker fires. `nil` when nothing changes (or the markup is a reference).
    private func substituteExchangeMacros(in markup: AdMarkup, candidate: AdCandidate, input: ParsedInput) -> AdMarkup? {
        let text: String
        let rebuild: (String) -> AdMarkup
        switch markup {
        case let .html(adm): (text, rebuild) = (adm, AdMarkup.html)
        case let .native(json): (text, rebuild) = (json, AdMarkup.native)
        case let .vast(.xml(xml)): (text, rebuild) = (xml, { .vast(.xml($0)) })
        case .vast(.url), .image, .none: return nil
        }
        let expanded = services.expandMarkup(text, macroContext(for: candidate, input: input, adIndex: nil))
        var notes: [String] = []
        if !expanded.replaced.isEmpty { notes.append("substituted " + Set(expanded.replaced).sorted().joined(separator: ", ")) }
        if !expanded.unknown.isEmpty { notes.append("unknown, left as is: " + Set(expanded.unknown).sorted().joined(separator: ", ")) }
        if !notes.isEmpty { log("adm macros: " + notes.joined(separator: "; "), origin: "exchange", outcome: .fired(requests: 0)) }
        return expanded.url == text ? nil : rebuild(expanded.url)
    }

    /// HTML or Native markup fetched after the win (`display.curl`, the nurl response) still carrying OpenRTB `${…}`
    /// macros: they stay literal — only the exchange substitutes them, and only in the bid response (OpenRTB 2.6 §4.4).
    /// VAST documents get the resolver's own warning.
    nonisolated static func unsubstitutedMacroIssue(in markup: AdMarkup, deliveredBy: String) -> ValidationIssue? {
        let text: String
        switch markup {
        case let .html(document), let .native(document): text = document
        case .vast, .image, .none: return nil
        }
        let macros = MacroExpander.unsubstitutedOpenRTBMacros(in: text)
        guard !macros.isEmpty else { return nil }
        let shownLimit = 5
        let shown = macros.prefix(shownLimit).joined(separator: ", ") + (macros.count > shownLimit ? ", …" : "")
        return ValidationIssue(.warning, code: "openrtb.macro.unsubstituted",
                               message: "Unsubstituted OpenRTB macro in the markup delivered by \(deliveredBy): \(shown) stays literal in the creative "
                                   + "and its trackers. Only the exchange substitutes ${…}, and only in the bid response (OpenRTB 2.6 §4.4); "
                                   + "markup fetched after the win must arrive filled in.",
                               path: deliveredBy)
    }

    /// Right after a VAST resolution (decisions.md): the Error URLs of `adFailures` once, then — when no ad could be
    /// produced — `.error(failure, adIndex: nil)` once. Renderers never report the chain failure themselves.
    private func resolutionFollowUps(_ vast: ResolvedVAST, candidate: AdCandidate, input: ParsedInput, source: String) {
        let context = macroContext(for: candidate, input: input, adIndex: nil)
        let requests = services.resolutionRequests(vast, context, source)
        log("VAST resolved: \(vast.ads.count) ad(s)" + (vast.failure.map { ", error \($0.rawValue)" } ?? ""), origin: "VAST",
            outcome: .fired(requests: dispatch(requests)))
        if let failure = vast.failure { deliver([.error(failure, adIndex: nil)], origin: "VAST", input: input) }
    }

    private func fireWonIfExchangeSendsIt(input: ParsedInput) {
        guard macros.exchangeSendsWinNotice else { return }
        deliver([.won], origin: "exchange", input: input)
    }

    static func viewabilityKind(markup: AdMarkup, format: AdFormat) -> ViewabilityController.Kind {
        switch markup {
        case .vast: format == .audio ? .audio : .video
        case .native: .native
        case .html, .image: .display
        case .none: .none
        }
    }

    /// Markup fetched from `display.curl` or the win notice: VAST XML, Native JSON, a VAST tag URL (video/audio) or HTML.
    static func markup(fromFetched body: String, format: AdFormat) -> AdMarkup {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.range(of: "<VAST", options: .caseInsensitive) != nil { return .vast(.xml(trimmed)) }
        if trimmed.hasPrefix("{"), format == .native || trimmed.contains("\"assets\"") || trimmed.contains("\"native\"") {
            return .native(trimmed)
        }
        if format == .video || format == .audio, let scheme = URLText.scheme(trimmed), scheme == "http" || scheme == "https",
           !trimmed.contains(where: \.isWhitespace) {
            return .vast(.url(trimmed))
        }
        return .html(body)
    }

    // MARK: Events

    /// A lifecycle event from the renderer or the manual controls.
    func report(_ event: AdLifecycleEvent) {
        handle(event, origin: "renderer")
    }

    /// The Fire controls.
    func fireManually(_ event: AdLifecycleEvent) {
        handle(event, origin: "manual")
    }

    private func handle(_ event: AdLifecycleEvent, origin: String) {
        guard phase == .ready, prepared != nil else {
            log(event.label, origin: origin, outcome: .ignored("no ad on the device"))
            return
        }
        if let problem = invalidIndex(in: event) {
            log(event.label, origin: origin, outcome: .ignored(problem))
            return
        }
        guard deliver([event], origin: origin) else { return }
        let now = clock.now()
        var follow: [AdLifecycleEvent] = []
        switch event {
        case .rendered:
            follow = viewability.rendered(at: now)
        case let .video(videoEvent, adIndex):
            currentAdIndex = adIndex
            follow = viewability.videoEvent(videoEvent, adIndex: adIndex, at: now)
        case .closed:
            follow = viewability.closed(at: now)
        default:
            break
        }
        deliver(follow, origin: "viewability")
        scheduleViewabilityTimer()
    }

    /// Renderer-reported indices are untrusted: an ad or companion index outside the resolved VAST is refused here, so
    /// it never reaches the tracking plan (or a gate key that blocks the real event).
    private func invalidIndex(in event: AdLifecycleEvent) -> String? {
        guard let adIndex = Self.adIndex(of: event) else { return nil }
        guard adIndex >= 0 else { return "negative ad index" }
        guard let vast = vast(for: event) else { return nil }
        guard let ad = vast.ads[safe: adIndex] else { return "no ad \(adIndex &+ 1) in the VAST (\(vast.ads.count))" }
        switch event {
        case let .companionView(_, companionIndex), let .companionClick(_, companionIndex):
            let companions = ad.inline.creatives.reduce(0) { $0 + $1.companions.count }
            guard companionIndex >= 0, companionIndex < companions else { return "no companion \(companionIndex &+ 1) in ad \(adIndex &+ 1)" }
            return nil
        case let .iconView(_, iconIndex), let .iconClick(_, iconIndex):
            guard ad.icons.indices.contains(iconIndex) else { return "no icon \(iconIndex &+ 1) in ad \(adIndex &+ 1)" }
            return nil
        default:
            return nil
        }
    }

    /// Admits each event through the gate and dispatches its trackers. Returns whether the first event fired.
    @discardableResult
    private func deliver(_ events: [AdLifecycleEvent], origin: String, input: ParsedInput? = nil) -> Bool {
        var firstFired = false
        for (index, event) in events.enumerated() {
            guard let prepared else { break }
            let verdict = gate.admit(event)
            switch verdict {
            case .alreadyFired:
                log(event.label, origin: origin, outcome: .alreadyFired)
            case .contradictsOutcome:
                log(event.label, origin: origin, outcome: .contradictsOutcome)
            case .admitted:
                if index == 0 { firstFired = true }
                let lossReason = if case let .loss(reason) = event { reason } else { LossReason.bidWon.code }
                let context = macroContext(for: prepared.candidate, input: input ?? renderInput, adIndex: Self.adIndex(of: event),
                                           lossReason: lossReason)
                let options = TrackingPlanOptions(exchangeSendsWinNotice: macros.exchangeSendsWinNotice && !prepared.markupFromWinNotice,
                                                  markupRequestID: prepared.markupEntryID)
                let requests = services.trackingRequests(event, prepared.candidate, prepared.native, vast(for: event), context, options)
                log(event.label, origin: origin, outcome: .fired(requests: dispatch(requests)))
            }
        }
        return firstFired
    }

    private func vast(for event: AdLifecycleEvent) -> ResolvedVAST? {
        prepared?.native != nil ? nativeVideoVAST : prepared?.vast
    }

    private static func adIndex(of event: AdLifecycleEvent) -> Int? {
        switch event {
        case let .video(_, adIndex), let .videoViewability(_, adIndex), let .videoClick(adIndex), let .companionView(adIndex, _),
             let .companionClick(adIndex, _), let .iconView(adIndex, _), let .iconClick(adIndex, _):
            adIndex
        case let .error(_, adIndex):
            adIndex
        default:
            nil
        }
    }

    /// Dispatches trackers with the device's User-Agent; navigations are recorded (and opened only when allowed). Each
    /// keeps the parent the plan gave it: the request that delivered the document its URL is in, never a tracker.
    @discardableResult
    private func dispatch(_ requests: [TrackerRequest]) -> Int {
        var sentNotices = 0
        for var request in requests {
            if let prepared { request.source = AuctionReplays.source(request.source, candidateID: prepared.candidate.id, replay: replay) }
            if request.category == .navigation {
                recordNavigation(url: request.url, trigger: request.trigger, source: request.source, parentID: request.parentID)
                continue
            }
            let entryID = monitor.dispatch(request, userAgent: device.userAgent)
            if request.isScript, monitor.mode == .real {
                scriptTrackers.append(ScriptTracker(entryID: entryID, request: request))
            }
            if monitor.mode == .real, AuctionReplays.noticeCategories.contains(request.category) { sentNotices += 1 }
        }
        if let playedAuction { replays.noteSent(sentNotices, auction: playedAuction) }
        return requests.count
    }

    private func recordNavigation(url: String, trigger: String, source: String, parentID: UUID?) {
        var opened = false
        if NetworkPreferences.shouldOpenInBrowser(url, mode: monitor.mode, settingEnabled: opensClickThroughs(), device: device),
           let target = URLText.requestURL(url) {
            opened = browser.open(target)
            if !opened { log(trigger, origin: source, outcome: .ignored("no default web browser: the click-through was not opened")) }
        }
        monitor.recordNavigation(url: url, trigger: trigger, source: source, parentID: parentID, openedInBrowser: opened)
    }

    func macroContext(for candidate: AdCandidate, input: ParsedInput, adIndex: Int?, lossReason: Int = LossReason.bidWon.code) -> MacroContext {
        macros.context(candidate: candidate, input: input, device: device, playerSize: adSize, transactionID: transactionID,
                       playhead: playback[adIndex ?? currentAdIndex]?.playhead, lossCode: lossReason,
                       assetURI: playback[adIndex ?? currentAdIndex]?.assetURI)
    }

    // MARK: Viewability timers

    /// Fires every viewability timer that has completed (the timer task calls this at each deadline; tests call it after
    /// moving the clock).
    func settleViewability() {
        guard phase == .ready else { return }
        deliver(viewability.advance(to: clock.now()), origin: "viewability")
        scheduleViewabilityTimer()
    }

    private func scheduleViewabilityTimer() {
        viewabilityTimer?.cancel()
        guard phase == .ready, let deadline = viewability.nextDeadline else { return }
        let delay = max(0, deadline - clock.now())
        let token = generation
        viewabilityTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay) + .milliseconds(5)) } catch { return }
            guard let self, self.generation == token else { return }
            self.settleViewability()
        }
    }

    /// Progress (0…1) of a display viewability timer, for the simulator's readout.
    func viewabilityProgress(of level: ViewabilityLevel) -> Double {
        viewability.displayProgress(of: level, at: clock.now())
    }

    func hasFired(_ event: AdLifecycleEvent) -> Bool { gate.hasFired(event) }

    // MARK: Playback (renderer)

    /// The player's state, about 4 Hz and on every play / pause / seek / end: `[ADPLAYHEAD]` and the video viewability
    /// timers. Reports with a negative ad index or a non-finite playhead are ignored.
    func playbackChanged(_ status: PlaybackStatus) {
        guard phase == .ready, status.adIndex >= 0, status.playhead.isFinite, status.playhead >= 0 else { return }
        playback[status.adIndex] = status
        currentAdIndex = status.adIndex
        deliver(viewability.playback(adIndex: status.adIndex, isPlaying: status.isPlaying, at: clock.now()), origin: "viewability")
        scheduleViewabilityTimer()
    }

    // MARK: Renderer services

    /// A destination only the creative knows (`mraid.open`, `window.open`, an anchor): its URL is in the markup, so its
    /// parent is the request that delivered the markup (`nil` for inline adm), never the click tracker.
    func navigate(to url: String, trigger: String, source: String) {
        guard phase == .ready else { return }
        recordNavigation(url: url, trigger: trigger, source: source, parentID: prepared?.markupEntryID)
    }

    /// A destination a VAST companion's own document opened (HTML / iframe / script companions): its URL is in ad
    /// `vastAdIndex`'s inline document, so its parent is the hop that delivered that document — the parent of the ad's
    /// media and companion loads. An index outside the bid's VAST is refused.
    func navigate(to url: String, trigger: String, source: String, vastAdIndex: Int) {
        guard phase == .ready, let prepared else { return }
        guard let vast = prepared.vast, vastAdIndex >= 0, let ad = vast.ads[safe: vastAdIndex] else {
            log(trigger, origin: "renderer", outcome: .ignored("no ad \(vastAdIndex &+ 1) in the bid's VAST"))
            return
        }
        let parent = ad.origin.last.flatMap { vast.chain[safe: $0.hop]?.requestID }
        recordNavigation(url: url, trigger: trigger, source: source, parentID: parent)
    }

    func fetchContent(_ url: String, trigger: String, source: String) async throws -> Data {
        try await monitor.fetchContent(url, category: .content, trigger: trigger, source: source, parentID: prepared?.markupEntryID,
                                       userAgent: device.userAgent).data
    }

    /// A Native video asset's VAST (the host requirement): resolved through the monitor (`MonitorVASTFetcher`), so every
    /// wrapper hop is a content entry under the markup's entry, and remembered for the asset's `.video(e, adIndex:)`
    /// events. Concurrent and repeated calls for the same source share one resolution and its follow-ups.
    func resolveVAST(_ source: VASTSource) async -> ResolvedVAST {
        guard phase == .ready, let prepared else { return ResolvedVAST() }
        if let pending = nativeVideoResolution, pending.source == source { return await pending.task.value }
        let token = generation
        let parent = prepared.markupEntryID
        let label = sourceRoot(prepared.candidate) + " › native video"
        let fetcher = MonitorVASTFetcher(monitor: monitor, userAgent: device.userAgent, source: label, rootParentID: parent, resolving: source)
        let resolve = services.resolveVAST
        let context = macroContext(for: prepared.candidate, input: renderInput, adIndex: nil)
        let task = Task { await resolve(source, fetcher, parent, context) }
        nativeVideoResolution = (source, task)
        let resolved = await task.value
        guard token == generation, phase == .ready else { return resolved }
        nativeVideoVAST = resolved
        renderIssues += resolved.issues
        resolutionFollowUps(resolved, candidate: prepared.candidate, input: renderInput, source: label)
        return resolved
    }

    /// The renderer console (MRAID bridge, VAST player, Native, HTML); the oldest lines go beyond `consoleCapacity`.
    func rendererLog(_ entry: RendererLogEntry) {
        consoleSequence &+= 1
        console.append(ConsoleLine(id: consoleSequence, entry: entry))
        if console.count > Self.consoleCapacity { console.removeFirst(console.count - Self.consoleCapacity) }
    }

    func clearConsole() { console.removeAll() }

    // MARK: Tracking mode

    /// Asks to switch to Real mode: shows the confirmation listing the tracker hosts of the bid it would act on. The mode
    /// does not change until `confirmRealMode(_:)`.
    func requestRealMode() {
        guard monitor.mode != .real else { return }
        realModeConfirmation = RealModeConfirmation(target: realModeTarget())
        reviewNativeVideoIfNeeded()
    }

    /// The Native ad Real mode would be confirmed for: the one on the device, else the inspected one.
    private var realModeNative: NativeAd? {
        let candidate = realModeCandidate
        if candidate != nil, candidate?.id == prepared?.candidate.id { return prepared?.native }
        return candidate?.id == selectedCandidateID ? inspectedNative : nil
    }

    /// Resolves the Native video tag of the bid under review once, then re-prompts with its trackers.
    private func reviewNativeVideoIfNeeded() {
        guard realModeConfirmation != nil, let candidateID = realModeCandidate?.id, let native = realModeNative,
              let source = native.assets.lazy.compactMap(\.vastSource).first, case .url = source else { return }
        if candidateID == prepared?.candidate.id, nativeVideoVAST != nil { return }
        if let reviewed = reviewedNativeVideo, reviewed.candidateID == candidateID, reviewed.revision == inputRevision, reviewed.source == source {
            return
        }
        let revision = inputRevision
        reviewedNativeVideo = (candidateID, revision, source, nil)
        let parent = candidateID == prepared?.candidate.id ? prepared?.markupEntryID : nil
        let fetcher = MonitorVASTFetcher(monitor: monitor, userAgent: device.userAgent, source: "bid \(candidateID) › native video (Real-mode review)",
                                         rootParentID: parent, resolving: source)
        let resolve = services.resolveVAST
        let context = realModeCandidate.map { macroContext(for: $0, input: parsed, adIndex: nil) } ?? MacroContext()
        Task { [weak self] in
            let resolved = await resolve(source, fetcher, parent, context)
            guard let self, let pending = self.reviewedNativeVideo, pending.candidateID == candidateID, pending.revision == revision,
                  pending.source == source else { return }
            self.reviewedNativeVideo = (candidateID, revision, source, resolved)
            self.refreshRealModeConfirmation()
        }
    }

    /// The bid Real mode is confirmed for: the one on the device while it is the selected bid, else the selected bid.
    private var realModeCandidate: AdCandidate? {
        if let prepared, prepared.candidate.id == selectedCandidateID { return prepared.candidate }
        return selectedCandidate
    }

    /// The snapshot a confirmation shows and acts on.
    private func realModeTarget() -> RealModeTarget {
        let candidate = realModeCandidate
        let onDevice = candidate != nil && candidate?.id == prepared?.candidate.id
        let native = realModeNative
        let resolved = onDevice ? prepared?.vast : nil
        let documents = (resolved == nil && candidate?.id == selectedCandidateID) ? [inspectedVAST].compactMap { $0 } : []
        let reviewed = reviewedNativeVideo.flatMap { $0.candidateID == candidate?.id && $0.revision == inputRevision ? $0.resolved : nil }
        let nativeVideo = (onDevice ? nativeVideoVAST : nil) ?? reviewed
        let summary = TrackerHosts.summary(candidate: candidate, native: native, vastDocuments: documents, resolved: resolved,
                                           nativeVideo: nativeVideo)
        return RealModeTarget(candidateID: candidate?.id, bidLabel: candidate.map { "bid \($0.bidID)" + ($0.seat.map { " · seat \($0)" } ?? "") },
                              summary: summary, inputRevision: inputRevision, generation: generation, deviceID: device.id,
                              placement: placement, landscape: landscape, folded: folded, spanned: spanned,
                              sentNotices: candidate.flatMap { candidate in
                                  let auction = auctionKey(candidate, input: parsed)
                                  return replays.sentNotices(auction: auction.key, auctionID: auction.auctionID)
                              })
    }

    /// A shown confirmation always describes the current target: anything that changed it re-prompts with a new snapshot.
    private func refreshRealModeConfirmation() {
        guard let shown = realModeConfirmation else { return }
        let target = realModeTarget()
        defer { reviewNativeVideoIfNeeded() }
        guard target != shown.target else { return }
        realModeConfirmation = RealModeConfirmation(target: target)
        log("Real mode: what would be confirmed changed; confirm the new list", origin: "mode", outcome: .ignored("re-prompted"))
    }

    /// Enters Real mode, only with the confirmation currently shown and only if it still describes the current target.
    /// The ad of another bid on the device is removed (nothing unlisted can send); a bid waiting for its win notice to
    /// deliver the markup is rendered now — exactly the confirmed one.
    func confirmRealMode(_ confirmation: RealModeConfirmation) {
        guard realModeConfirmation?.id == confirmation.id else { return }
        guard confirmation.target == realModeTarget() else {
            refreshRealModeConfirmation()
            return
        }
        realModeConfirmation = nil
        let anotherBidOnTheDevice = prepared.map { $0.candidate.id != confirmation.target.candidateID } ?? false
        monitor.mode = .real
        log("Real mode on: trackers are sent", origin: "mode", outcome: .fired(requests: 0))
        if anotherBidOnTheDevice {
            reset()
        } else if case .needsRealMode = phase {
            render()
        }
    }

    func cancelRealMode() {
        realModeConfirmation = nil
    }

    /// The content hosts the current render contacted (the VAST tag and wrappers, images, media, markup by reference):
    /// they see the device's requests in Simulated mode too.
    var contactedContentHosts: [TrackerHosts.Host] {
        TrackerHosts.contentHosts(monitor.liveEntries.filter { $0.sequence > renderStartSequence })
    }

    /// The toolbar's mode: Offline, Simulated or Real.
    var sessionMode: SessionMode { SessionMode(monitor) }

    /// Switches to `mode`: Real only asks (`requestRealMode`).
    func choose(_ mode: SessionMode) {
        switch mode {
        case .offline: useOfflineMode()
        case .simulated: useSimulatedMode()
        case .real: requestRealMode()
        }
    }

    /// Offline: Simulated tracking, and no content from the network — only `data:` URLs and built-in samples load. Ends
    /// Real mode at once, and cancels every request in flight, content included.
    func useOfflineMode() {
        realModeConfirmation = nil
        guard !monitor.offline else { return }
        monitor.offline = true
        // The renderers tear down every Real-mode script tracker web view when the list empties.
        scriptTrackers = []
        log("Offline: nothing is loaded or sent; only data: URLs and built-in samples", origin: "mode", outcome: .fired(requests: 0))
    }

    func useSimulatedMode() {
        realModeConfirmation = nil
        if monitor.offline {
            monitor.offline = false
            log("Simulated mode: trackers are recorded, not sent; content loads from the markup's URLs", origin: "mode", outcome: .fired(requests: 0))
            return
        }
        guard monitor.mode != .simulated else { return }
        monitor.mode = .simulated
        // The renderers tear down every Real-mode script tracker web view when the list empties.
        scriptTrackers = []
        log("Simulated mode: trackers are recorded, not sent", origin: "mode", outcome: .fired(requests: 0))
    }

    // MARK: Log

    private func log(_ label: String, origin: String, outcome: LifecycleLogEntry.Outcome) {
        logSequence &+= 1
        lifecycleLog.append(LifecycleLogEntry(id: logSequence, time: Date(), label: label, origin: origin, outcome: outcome))
        if lifecycleLog.count > Self.lifecycleLogCapacity { lifecycleLog.removeFirst(lifecycleLog.count - Self.lifecycleLogCapacity) }
    }

    func clearLifecycleLog() { lifecycleLog.removeAll() }
}

/// Inline banner anchoring in the mock news app.
enum BannerPosition: String, CaseIterable, Identifiable, Sendable {
    case top = "Top"
    case bottom = "Bottom"
    var id: String { rawValue }
}

/// The Real-mode confirmation: the hosts trackers would go to.
/// The confirmation before Real mode: an immutable snapshot of what the user is shown and what confirming acts on.
struct RealModeConfirmation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let target: RealModeTarget
    var bidLabel: String? { target.bidLabel }
    var summary: TrackerHosts.Summary { target.summary }
}

/// What a Real-mode confirmation covers: the bid (its label and exact host list), the render generation, the device and
/// placement. Confirming acts on exactly this; anything that differs re-prompts (safety review).
struct RealModeTarget: Equatable, Sendable {
    var candidateID: String?
    var bidLabel: String?
    var summary: TrackerHosts.Summary
    var inputRevision: Int
    var generation: Int
    var deviceID: String
    var placement: Placement
    var landscape: Bool
    var folded: Bool
    var spanned: Bool
    /// Notices of this bid's auction already sent this session (sending again may double-count at the DSP).
    var sentNotices: AuctionReplays.SentNotices? = nil
}

/// One line of the renderer console, numbered in arrival order.
struct ConsoleLine: Identifiable, Equatable, Sendable {
    let id: Int
    let entry: RendererLogEntry
}
