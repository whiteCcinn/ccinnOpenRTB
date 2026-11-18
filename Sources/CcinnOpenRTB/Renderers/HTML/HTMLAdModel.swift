import CcinnOpenRTBKit
import Foundation
import Observation
import RTBKit

/// Drives one HTML creative (with the MRAID container) and maps what it does to lifecycle events:
/// - `.rendered` once, when the document finished loading;
/// - a click-through (user-gesture navigation, `window.open`, `target=_blank`, `mraid.open`) → `.click(assetID: nil)`, then
///   `host.navigate` (the tracking plan cannot know the URL); none on devices without click-through;
/// - MRAID `hidden` (the creative's `close()` / `unload()`, or the container's close) → `.closed` once;
/// - `expand` / `resize` / custom close are state the view draws.
@MainActor
@Observable
final class HTMLAdModel {
    enum Status: Equatable {
        case loading, ready
        case failed(String)
    }

    /// What decides a (re)load of the document: the markup, the sandbox and the MRAID environment.
    struct LoadKey: Equatable {
        var markup: String
        var blocksNetwork: Bool
        var environment: MRAIDEnvironment
        var generation: Int
    }

    private(set) var status: Status = .loading
    private(set) var mraidState = "loading"
    private(set) var customClose = false
    /// The creative's size while `resized` (drawn inside the slot).
    private(set) var resizedSize: MRAIDSize?
    private(set) var isExpanded = false
    private(set) var isClosed = false
    /// Set by MRAID `expand()`: the expanded size (the max size, or the expand properties').
    private(set) var expandedSize: MRAIDSize?

    @ObservationIgnored let controller: CreativeWebController
    @ObservationIgnored private weak var host: (any AdRenderingHost)?
    @ObservationIgnored private var loadKey: LoadKey?
    @ObservationIgnored private var renderedReported = false
    @ObservationIgnored private var allowsClickThrough = true
    @ObservationIgnored private var source = "creative"
    @ObservationIgnored private(set) var isTornDown = false

    init(host: any AdRenderingHost) {
        self.host = host
        controller = CreativeWebController(host: host)
        controller.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Whether the creative's own network is blocked now (Simulated mode without "Allow creative network").
    static func blocksNetwork(_ monitor: NetworkMonitor) -> Bool {
        monitor.mode == .simulated && !monitor.allowCreativeNetwork
    }

    static func loadKey(markup: String, request: RenderRequest, blocksNetwork: Bool) -> LoadKey {
        var environment = MRAIDEnvironment(request: request)
        // Exposure changes are pushed to the page; they never reload it.
        environment.exposedPercentage = 0
        return LoadKey(markup: markup, blocksNetwork: blocksNetwork, environment: environment, generation: request.generation)
    }

    /// Loads the creative, or reloads it when the markup, sandbox, device geometry or generation changed.
    func load(markup: String, request: RenderRequest, blocksNetwork: Bool) {
        guard !isTornDown else { return }
        let key = Self.loadKey(markup: markup, request: request, blocksNetwork: blocksNetwork)
        guard key != loadKey else { return }
        let reload = loadKey != nil
        loadKey = key
        allowsClickThrough = request.allowsClickThrough
        source = request.sourceRoot + " › adm"
        status = .loading
        mraidState = "loading"
        customClose = false
        resizedSize = nil
        isExpanded = false
        expandedSize = nil
        if reload { log(.info, "Reloading the creative (markup, sandbox or device changed)") }
        if blocksNetwork {
            log(.info, "Simulated mode: the creative's own network is blocked; attempts are recorded as blocked")
        }
        let environment = MRAIDEnvironment(request: request)
        controller.load(CreativeWebController.Content(document: HTMLDocumentBuilder.document(for: markup), mraid: environment,
                                                      blocksNetwork: blocksNetwork, disableScroll: environment.disableScroll,
                                                      networkParentID: nil, source: source))
    }

    func setVisibleFraction(_ fraction: Double) {
        controller.updateExposure(MRAIDEnvironment.percentage(fraction))
    }

    /// The container's close (chrome X, the expanded view's close): MRAID goes back to `default` from expanded / resized,
    /// to `hidden` otherwise. A full-screen ad is closed at once, whatever the page does.
    func containerClose(fullscreen: Bool) {
        if isExpanded || mraidState == "resized" {
            controller.containerClose()
            return
        }
        controller.containerClose()
        if fullscreen { markClosed() }
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        controller.teardown()
    }

    // MARK: Events

    private func handle(_ event: CreativeWebController.Event) {
        guard !isTornDown else { return }
        switch event {
        case .loaded:
            status = .ready
            if !renderedReported {
                renderedReported = true
                host?.report(.rendered)
            }
        case let .failed(message):
            status = .failed(message)
        case let .click(url, trigger):
            clickThrough(url, trigger: "HTML \(trigger)")
        case let .mraidOpen(url):
            clickThrough(url, trigger: "mraid.open")
        case let .mraidState(state, custom, size):
            apply(state: state, customClose: custom, size: size)
        case let .mraidCommand(command):
            perform(command)
        }
    }

    private func clickThrough(_ url: String, trigger: String) {
        guard allowsClickThrough else {
            log(.info, "\(trigger) \(url): click-through is disabled on this device")
            return
        }
        host?.report(.click(assetID: nil))
        host?.navigate(to: url, trigger: trigger, source: source)
    }

    private func apply(state: String, customClose custom: Bool, size: MRAIDSize?) {
        let previous = mraidState
        mraidState = state
        customClose = custom
        switch state {
        case "expanded":
            isExpanded = true
            expandedSize = size
            resizedSize = nil
        case "resized":
            isExpanded = false
            resizedSize = size
            if previous != "resized", let size {
                log(.info, "Resized to \(Int(size.width))×\(Int(size.height)); the simulator draws it inside the ad slot")
            }
        case "hidden":
            isExpanded = false
            resizedSize = nil
            markClosed()
        default:
            isExpanded = false
            resizedSize = nil
        }
    }

    private func perform(_ command: MRAIDCommand) {
        switch command {
        case let .expand(url?):
            log(.warning, "Two-part expand (\(url)) is shown as a one-part expand: the simulator does not load the second document")
        case let .playVideo(url):
            guard allowsClickThrough else { return }
            host?.navigate(to: url, trigger: "mraid.playVideo (native player)", source: source)
        case .open, .close, .unload, .expand, .resize, .useCustomClose, .other:
            // State changes arrive as `mraidState`; `open` as `mraidOpen`.
            break
        }
    }

    private func markClosed() {
        guard !isClosed else { return }
        isClosed = true
        host?.report(.closed)
    }

    private func log(_ level: RendererLogEntry.Level, _ message: String) {
        host?.rendererLog(RendererLogEntry(.html, level, message))
    }
}
