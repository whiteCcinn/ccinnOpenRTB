import AVFoundation
import CcinnOpenRTBKit
import CoreGraphics
import Foundation
import Observation
import RTBKit

/// Picks the media file to play (`VASTMediaSelector.choose` in the app; injectable for tests and the demo harness).
typealias VASTMediaChooser = @Sendable (_ files: [VASTMediaFile], _ playerWidth: Int, _ playerHeight: Int, _ audioOnly: Bool)
    -> VASTMediaSelector.Choice

/// How a player behaves in its placement.
struct VASTPlayerConfiguration: Sendable {
    /// Below this visible fraction an inline player pauses (and resumes above it), as in-feed players do.
    static let visibilityThreshold = 0.5

    var placement: Placement
    var device: DeviceProfile
    var playerSize: CGSize
    var audioOnly: Bool
    /// Network source prefix: `bid 0.0 › VAST`.
    var source: String
    /// The player reports `.rendered` (billing) at the first frame; `false` for a Native ad's video asset, whose
    /// impression is the Native ad's own.
    var reportsRendered = true
    var showsCompanions = true
    var readyTimeout: Duration = .seconds(15)

    var isCTV: Bool { device.family == .ctv || placement == .ctvInstream }
    var allowsClickThrough: Bool { !isCTV && device.supportsClickThrough }
    /// Rewarded ads are watched to the end.
    var skipEnabled: Bool { placement != .rewarded }
    var isInline: Bool { placement == .inFeed || placement == .inlineBanner }
    /// In-feed video autoplays muted; full-screen, CTV and audio ads play with sound.
    var startsMuted: Bool { isInline && !audioOnly }
}

/// Plays a resolved VAST pod and reports its lifecycle (decisions.md), per pod ad i:
/// `.video(.loaded, i)` → at the first frame of the first ad that plays `.rendered` (once) → `.video(.creativeView, i)` →
/// `.video(.start, i)` → quartiles and `progress` offsets (each once, via `VASTPlaybackTracker`) → `complete`, `skip` or
/// `closeLinear` (+ `.closed`). Unplayable ads report `.error(code, adIndex: i)` and the pod moves on. Playback status
/// goes to `playbackChanged` about 4 times a second and on every change; viewability is the shell's job.
///
/// Main-actor only. `teardown()` stops everything silently (no tracking): call it when the view goes away.
@MainActor
@Observable
final class VASTPlayerModel {
    enum Phase: Equatable {
        case idle, loading, playing, finished, closed
    }

    struct EndCard: Equatable {
        var choice: CompanionChoice
        var adIndex: Int
    }

    private enum AdOutcome {
        case completed, skipped, failed, closed, cancelled
    }

    let items: [VASTPodItem]
    let configuration: VASTPlayerConfiguration
    private(set) var phase: Phase = .idle
    private(set) var currentItem: VASTPodItem?
    private(set) var playhead: Double = 0
    private(set) var duration: Double?
    private(set) var isPlaying = false
    private(set) var isMuted: Bool
    private(set) var skipState: SkipButtonState = .hidden
    private(set) var endCard: EndCard?
    /// Pod ads that reached their first frame.
    private(set) var startedAds = 0
    /// The current ad reached its first frame (`creativeView`): its companions may show from now on.
    private(set) var currentAdStarted = false
    /// The last media error the player reported (shown when no ad could play).
    private(set) var lastError: VASTErrorCode?

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private weak var host: (any AdRenderingHost)?

    /// The session is Offline: content from the network is not loaded (read in view bodies, so it updates with the monitor).
    var contentIsOffline: Bool { host?.monitor.offline ?? false }
    @ObservationIgnored private let chooseMedia: VASTMediaChooser
    @ObservationIgnored private var tracker: VASTPlaybackTracker?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var outcome: CheckedContinuation<AdOutcome, Never>?
    @ObservationIgnored private var adActive = false
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var renderedReported = false
    @ObservationIgnored private var pendingMedia: (id: UUID, mimeType: String?)?
    @ObservationIgnored private var viewedCompanions: Set<[Int]> = []
    /// Companions reported shown before their ad started, viewed right after the ad's `creativeView`.
    @ObservationIgnored private var pendingCompanionViews: [(choice: CompanionChoice, adIndex: Int)] = []
    /// The current ad's icons already shown (IconViewTracking fires once per icon).
    @ObservationIgnored private var shownIcons: Set<Int> = []
    @ObservationIgnored private var lastStatus: PlaybackStatus?
    @ObservationIgnored private var userPaused = false
    @ObservationIgnored private var hiddenPaused = false
    @ObservationIgnored private var visibleFraction = 1.0

    init(vast: ResolvedVAST, configuration: VASTPlayerConfiguration, host: any AdRenderingHost, engine: any PlaybackEngine,
         chooseMedia: @escaping VASTMediaChooser = VASTMediaSelector.choose) {
        let showsCompanions = configuration.showsCompanions && !configuration.isCTV
        items = VASTPodPlan.items(for: vast, source: configuration.source,
                                  canShowCompanion: { showsCompanions && CompanionPicker.resource(of: $0) != nil })
        self.configuration = configuration
        self.host = host
        self.engine = engine
        self.chooseMedia = chooseMedia
        isMuted = configuration.startsMuted
    }

    // MARK: State for the views

    var adCount: Int { items.count }
    var isTornDown: Bool { stopped }
    var adNumber: Int { (currentItem?.adIndex ?? 0) + 1 }
    var showsLearnMore: Bool { configuration.allowsClickThrough && currentItem?.clickThrough != nil && phase == .playing }

    /// The industry icons on screen now: the current ad's, from its first frame, each in its offset/duration window. None
    /// on CTV.
    var visibleIcons: [PlayerIcon] {
        guard !configuration.isCTV, currentAdStarted, phase == .playing, let item = currentItem else { return [] }
        return item.icons.filter { $0.isVisible(at: playhead) }
    }

    /// An icon is on screen: its IconViewTracking, once.
    func iconAppeared(_ icon: PlayerIcon) {
        guard !stopped, let item = currentItem, item.icons.contains(icon), shownIcons.insert(icon.iconIndex).inserted else { return }
        log(.info, "Ad \(item.adIndex &+ 1): icon \(icon.program ?? "") shown")
        host?.report(.iconView(adIndex: item.adIndex, iconIndex: icon.iconIndex))
    }

    /// A click on an icon: its IconClickTracking, then the IconClickThrough navigation (the tracking plan).
    func iconClicked(_ icon: PlayerIcon) {
        guard !stopped, let item = currentItem, item.icons.contains(icon) else { return }
        log(.info, "Ad \(item.adIndex &+ 1): icon \(icon.program ?? "") clicked")
        host?.report(.iconClick(adIndex: item.adIndex, iconIndex: icon.iconIndex))
    }
    var remaining: Double { PlayerClock.remaining(playhead: playhead, duration: duration) }
    var progress: Double { PlayerClock.fraction(playhead: playhead, duration: duration) }
    /// The engine's player, for the video layer.
    var avPlayer: AVPlayerReference { AVPlayerReference(player: engine.avPlayer) }

    // MARK: Lifecycle

    func start() {
        guard runTask == nil, !stopped else { return }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        guard !items.isEmpty else {
            phase = .finished
            return
        }
        runTask = Task { [weak self] in await self?.runPod() }
    }

    /// Stops playback and observers without reporting anything (the view went away or the shell re-renders).
    func teardown() {
        guard !stopped else { return }
        stopped = true
        timeoutTask?.cancel()
        timeoutTask = nil
        finishPendingMedia(status: nil, error: "Player closed before the media was ready")
        engine.onEvent = nil
        engine.stop()
        if isPlaying {
            isPlaying = false
            reportStatus(force: true)
        }
        resolve(.cancelled)
        runTask?.cancel()
        runTask = nil
    }

    // MARK: User actions

    func togglePlayback() {
        guard adActive, isReady else { return }
        if isPlaying {
            userPaused = true
            pausePlayback()
        } else {
            userPaused = false
            hiddenPaused = false
            resumePlayback()
        }
    }

    func toggleMute() {
        guard adActive else { return }
        isMuted.toggle()
        engine.setMuted(isMuted)
        if let item = currentItem, let events = tracker?.setMuted(isMuted) { emit(events, item) }
        reportStatus(force: true)
    }

    func skip() {
        guard adActive, isReady, skipState == .available, let item = currentItem, let events = tracker?.skip(), !events.isEmpty else { return }
        emit(events, item)
        engine.pause()
        isPlaying = false
        reportStatus(force: true)
        log(.info, "Skipped at \(PlayerClock.format(playhead))")
        resolve(.skipped)
    }

    /// "Learn more" / a click on the video: `.videoClick`, whose tracking plan fires the merged `ClickTracking` and then
    /// records the `ClickThrough` navigation (decisions.md), so the player does not navigate itself.
    func clickThrough() {
        guard configuration.allowsClickThrough, let item = currentItem, adActive || phase == .finished else { return }
        host?.report(.videoClick(adIndex: item.adIndex))
        if let url = item.clickThrough {
            log(.info, "Ad \(item.adIndex + 1) clicked: ClickThrough \(url)")
        } else {
            log(.warning, "Ad \(item.adIndex + 1) clicked without a ClickThrough URL: ClickTracking only")
        }
        if isPlaying {
            userPaused = true
            pausePlayback()
        }
    }

    /// The user closed the ad (close button, CTV Back): `closeLinear` while an ad plays, then `.closed`.
    func close() {
        guard !stopped, phase != .closed else { return }
        if adActive, let item = currentItem, let events = tracker?.close() { emit(events, item) }
        host?.report(.closed)
        phase = .closed
        timeoutTask?.cancel()
        finishPendingMedia(status: nil, error: "Closed before the media was ready")
        engine.stop()
        if isPlaying {
            isPlaying = false
            reportStatus(force: true)
        }
        resolve(.closed)
    }

    /// The shell's visible fraction: inline players pause below 50% and resume above it (unless the user paused).
    func setVisibleFraction(_ fraction: Double) {
        visibleFraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        guard configuration.isInline, adActive, isReady else { return }
        let visible = visibleFraction >= VASTPlayerConfiguration.visibilityThreshold
        if !visible, isPlaying {
            hiddenPaused = true
            pausePlayback()
        } else if visible, hiddenPaused, !userPaused {
            hiddenPaused = false
            resumePlayback()
        }
    }

    // MARK: Companions

    /// The request that delivered ad `adIndex`'s inline document (`nil` for markup carried in the bid): the network parent
    /// of its media and of its companions' requests.
    func documentRequestID(adIndex: Int) -> UUID? {
        items.indices.contains(adIndex) ? items[adIndex].mediaParentID : nil
    }

    /// A companion is on screen: its `creativeView`, once per companion. A companion is part of its ad: one shown before
    /// the ad's first frame is viewed right after the ad's `creativeView` (after the impression), never before it.
    func companionDidAppear(_ choice: CompanionChoice, adIndex: Int) {
        guard !stopped else { return }
        if currentItem?.adIndex == adIndex, !currentAdStarted {
            if !pendingCompanionViews.contains(where: { $0.adIndex == adIndex && $0.choice.companionIndex == choice.companionIndex }) {
                pendingCompanionViews.append((choice, adIndex))
            }
            return
        }
        guard viewedCompanions.insert([adIndex, choice.companionIndex]).inserted else { return }
        host?.report(.companionView(adIndex: adIndex, companionIndex: choice.companionIndex))
    }

    /// A click on a companion: `.companionClick` (its tracking plan fires `CompanionClickTracking`). Exactly one navigation
    /// follows (decisions "Renderer contract rulings"): for an image the plan records the `CompanionClickThrough`
    /// navigation; an HTML / iframe / script companion opened `url` itself, which the player records. Never on CTV.
    func companionClicked(_ choice: CompanionChoice, adIndex: Int, url: String?) {
        guard !stopped, configuration.allowsClickThrough else { return }
        host?.report(.companionClick(adIndex: adIndex, companionIndex: choice.companionIndex))
        if choice.playerOpensClickThrough {
            let clickThrough = choice.companion.clickThrough?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if clickThrough.isEmpty {
                log(.warning, "Companion \(choice.companionIndex + 1) of ad \(adIndex + 1) has no CompanionClickThrough: CompanionClickTracking only")
            }
            return
        }
        guard let opened = url?.trimmingCharacters(in: .whitespacesAndNewlines), !opened.isEmpty else { return }
        let source = items.indices.contains(adIndex) ? items[adIndex].source : configuration.source
        host?.navigate(to: opened, trigger: "companion creative navigation", source: source + " › Companion \(choice.companionIndex + 1)",
                       vastAdIndex: adIndex)
    }

    // MARK: Pod

    private func runPod() async {
        for item in items {
            guard !stopped else { return }
            let result = await play(item)
            if stopped || result == .closed || result == .cancelled { return }
        }
        finishPod()
    }

    private func play(_ item: VASTPodItem) async -> AdOutcome {
        begin(item)
        guard let host else { return .cancelled }
        guard item.linear != nil else {
            fail(item, code: item.missingLinearError, "Ad \(item.adIndex + 1) has no linear creative")
            return .failed
        }
        if let code = item.companionRequirementError {
            let reason = configuration.isCTV ? "a CTV player shows no companions" : "this player cannot show the companions it requires"
            fail(item, code: code, "Ad \(item.adIndex + 1) is not played: its CompanionAds are required and \(reason) (error \(code.rawValue))")
            return .failed
        }
        // MediaFile@width/@height are pixels (VAST 4.1 §3.9.1): the player's points at the device's scale.
        let width = Self.pixels(configuration.playerSize.width * configuration.device.scale)
        let height = Self.pixels(configuration.playerSize.height * configuration.device.scale)
        switch chooseMedia(item.mediaFiles, width, height, configuration.audioOnly) {
        case let .unsupported(code):
            fail(item, code: code, "No playable media file among \(item.mediaFiles.count) (error \(code.rawValue))")
            return .failed
        case let .play(file):
            log(.info, "Ad \(item.adIndex + 1): \(file.type ?? "media") \(file.width.map(String.init) ?? "?")×\(file.height.map(String.init) ?? "?") "
                + "for a \(width)×\(height) px player")
            let prepared = await host.monitor.prepareMedia(file.url, trigger: "media file", source: item.source + " › MediaFile",
                                                           parentID: item.mediaParentID, userAgent: host.device.userAgent)
            let remote = ["http", "https"].contains(URLText.scheme(file.url)?.lowercased() ?? "")
            guard !stopped else {
                if remote { host.monitor.finishRendererLoad(prepared.entryID, error: "Player closed before the media was ready") }
                return .cancelled
            }
            guard let url = prepared.playableURL else {
                fail(item, code: .fileNotFound, "The media file could not be prepared")
                return .failed
            }
            pendingMedia = remote ? (prepared.entryID, file.type) : nil
            tracker = VASTPlaybackTracker(duration: item.declaredDuration, progressOffsets: item.progressOffsets, muted: isMuted)
            adActive = true
            phase = .loading
            engine.setMuted(isMuted)
            engine.load(url, resourceLoader: prepared.resourceLoader)
            startReadyTimeout()
            return await withCheckedContinuation { continuation in outcome = continuation }
        }
    }

    private func begin(_ item: VASTPodItem) {
        currentItem = item
        currentAdStarted = false
        pendingCompanionViews.removeAll()
        shownIcons.removeAll()
        playhead = 0
        duration = item.declaredDuration
        isReady = false
        isPlaying = false
        userPaused = false
        hiddenPaused = false
        tracker = nil
        skipState = .hidden
        lastStatus = nil
    }

    private func finishPod() {
        phase = .finished
        isPlaying = false
        guard configuration.showsCompanions, !configuration.isCTV else { return }
        for item in items.reversed() {
            if let choice = CompanionPicker.pick(item.companions, fitting: nil) {
                endCard = EndCard(choice: choice, adIndex: item.adIndex)
                return
            }
        }
    }

    private func fail(_ item: VASTPodItem, code: VASTErrorCode, _ message: String) {
        lastError = code
        log(.error, message)
        host?.report(.error(code, adIndex: item.adIndex))
    }

    private func resolve(_ result: AdOutcome) {
        adActive = false
        guard let continuation = outcome else { return }
        outcome = nil
        continuation.resume(returning: result)
    }

    // MARK: Engine events

    private func handle(_ event: PlaybackEngineEvent) {
        guard !stopped, adActive, let item = currentItem else { return }
        switch event {
        case let .ready(mediaDuration):
            guard !isReady else { return }
            isReady = true
            timeoutTask?.cancel()
            finishPendingMedia(status: 200, error: nil)
            if let events = tracker?.loaded() { emit(events, item) }
            if let mediaDuration, mediaDuration > 0 {
                duration = mediaDuration
                if let events = tracker?.setDuration(mediaDuration) { emit(events, item) }
            }
            phase = .playing
            if configuration.isInline, visibleFraction < VASTPlayerConfiguration.visibilityThreshold {
                hiddenPaused = true
            } else {
                engine.play()
                isPlaying = true
            }
            updateSkip(item)
            reportStatus(force: true)
        case let .tick(time):
            guard isReady, time.isFinite, time >= 0 else { return }
            playhead = time
            if let events = tracker?.advance(to: time) { emit(events, item) }
            updateSkip(item)
            reportStatus(force: false)
        case .ended:
            guard isReady else { return }
            if let events = tracker?.complete() { emit(events, item) }
            if let duration { playhead = duration }
            isPlaying = false
            reportStatus(force: true)
            resolve(.completed)
        case let .failed(message):
            timeoutTask?.cancel()
            finishPendingMedia(status: nil, error: message)
            fail(item, code: isReady ? .mediaDisplayProblem : .fileNotFound, "Media failed: \(message)")
            engine.stop()
            if isPlaying {
                isPlaying = false
                reportStatus(force: true)
            }
            resolve(.failed)
        }
    }

    private func emit(_ events: [VASTEvent], _ item: VASTPodItem) {
        guard !events.isEmpty else { return }
        // The host reads `[ADPLAYHEAD]` from the last status: it must be the playhead these events fire at.
        reportStatusIfChanged()
        for event in events {
            if event == .creativeView {
                startedAds += 1
                currentAdStarted = true
                if configuration.reportsRendered, !renderedReported {
                    renderedReported = true
                    host?.report(.rendered)
                }
            }
            host?.report(.video(event, adIndex: item.adIndex))
        }
        if currentAdStarted, !pendingCompanionViews.isEmpty {
            let pending = pendingCompanionViews
            pendingCompanionViews.removeAll()
            for (choice, adIndex) in pending { companionDidAppear(choice, adIndex: adIndex) }
        }
    }

    private func pausePlayback() {
        engine.pause()
        isPlaying = false
        if let item = currentItem, let events = tracker?.pause() { emit(events, item) }
        reportStatus(force: true)
    }

    private func resumePlayback() {
        engine.play()
        isPlaying = true
        if let item = currentItem, let events = tracker?.resume() { emit(events, item) }
        reportStatus(force: true)
    }

    private func updateSkip(_ item: VASTPodItem) {
        skipState = SkipButtonState.make(skipOffset: item.skipOffset, playhead: playhead, duration: duration, enabled: configuration.skipEnabled)
    }

    private func startReadyTimeout() {
        timeoutTask?.cancel()
        let timeout = configuration.readyTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.readyTimedOut()
        }
    }

    private func readyTimedOut() {
        guard !stopped, adActive, !isReady, let item = currentItem else { return }
        finishPendingMedia(status: nil, error: "Timed out")
        fail(item, code: .mediaTimeout, "The media file was not ready in time")
        engine.stop()
        resolve(.failed)
    }

    private func finishPendingMedia(status: Int?, error: String?) {
        guard let pending = pendingMedia else { return }
        pendingMedia = nil
        host?.monitor.finishRendererLoad(pending.id, status: status, error: error, mimeType: pending.mimeType)
    }

    /// The current status at once, unless it is the one reported last (before events, for `[ADPLAYHEAD]`).
    private func reportStatusIfChanged() {
        guard let item = currentItem else { return }
        let status = PlaybackStatus(adIndex: item.adIndex, playhead: playhead, duration: duration, isPlaying: isPlaying, isMuted: isMuted)
        guard status != lastStatus else { return }
        lastStatus = status
        host?.playbackChanged(status)
    }

    /// About 4 Hz while playing (playhead steps of 0.25 s), and at once when play / mute / ad changes.
    private func reportStatus(force: Bool) {
        guard let item = currentItem else { return }
        let status = PlaybackStatus(adIndex: item.adIndex, playhead: playhead, duration: duration, isPlaying: isPlaying, isMuted: isMuted)
        if status == lastStatus { return }
        if !force, let last = lastStatus, last.isPlaying == status.isPlaying, last.isMuted == status.isMuted, last.adIndex == status.adIndex,
           abs(status.playhead - last.playhead) < 0.25 {
            return
        }
        lastStatus = status
        host?.playbackChanged(status)
    }

    private func log(_ level: RendererLogEntry.Level, _ message: String) {
        host?.rendererLog(RendererLogEntry(.vast, level, message))
    }

    private static func pixels(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return Int(min(value, 100_000).rounded())
    }
}

/// Wraps the engine's `AVPlayer` for SwiftUI (identity-compared, so views update only when the player changes).
struct AVPlayerReference: Equatable {
    let player: AVPlayer?

    static func == (lhs: AVPlayerReference, rhs: AVPlayerReference) -> Bool { lhs.player === rhs.player }
}
