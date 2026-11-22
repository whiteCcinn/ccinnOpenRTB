import CcinnOpenRTBKit
import Foundation
import RTBKit
import SwiftUI

enum ScriptTrackerDocument {
    /// A JavaScript URL (`<script src>`), or else markup (`jstracker` is HTML with its own `<script>` tags).
    static func isScriptURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URLText.scheme(trimmed)?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !trimmed.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" })
    }

    static func document(for request: TrackerRequest) -> String {
        let payload = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if isScriptURL(payload) {
            return HTMLDocumentBuilder.document(for: "<script src=\"\(HTMLEscaping.attribute(payload))\"></script>")
        }
        return HTMLDocumentBuilder.document(for: payload)
    }
}

/// Injects each Real-mode script tracker the host lists (`AdRenderingHost.scriptTrackers`) once, in its own hidden web view (non-persistent store, device User-Agent, the network
/// instrumentation recording its loads as children of the tracker's entry), and reports the injection's outcome with
/// `finishRendererLoad`: completed when the document (with its scripts) finished loading, failed on error, timeout,
/// teardown, or when the session is no longer in Real mode (nothing is injected then).
@MainActor
final class ScriptTrackerInjector {
    static let maxTrackers = 20
    static let timeout: Duration = .seconds(15)

    private weak var host: (any AdRenderingHost)?
    private var running: [UUID: CreativeWebController] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var lingering: [ObjectIdentifier: CreativeWebController] = [:]
    private var seen: Set<UUID> = []
    private var tornDown = false

    /// How long a finished tracker's page stays alive, so the outcomes of its own loads are still recorded.
    static let linger: Duration = .seconds(2)
    /// The outcome of a tracker still loading when it is torn down (Real mode ended, a new render, a reset).
    static let removedBeforeLoad = "The ad was removed before the script tracker loaded"

    init(host: any AdRenderingHost) {
        self.host = host
        host.adopt(self)
    }

    var runningCount: Int { running.count }
    var isTornDown: Bool { tornDown }

    func inject(_ trackers: [ScriptTracker]) {
        guard !tornDown, let host else { return }
        for tracker in trackers where seen.insert(tracker.entryID).inserted {
            let monitor = host.monitor
            guard monitor.mode == .real else {
                monitor.finishRendererLoad(tracker.entryID, error: "Not injected: the session is in Simulated mode")
                continue
            }
            guard seen.count <= Self.maxTrackers else {
                monitor.finishRendererLoad(tracker.entryID, error: "Not injected: more than \(Self.maxTrackers) script trackers")
                continue
            }
            start(tracker, host: host)
        }
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        for (entryID, controller) in running {
            controller.teardown()
            host?.monitor.finishRendererLoad(entryID, error: Self.removedBeforeLoad)
        }
        running.removeAll()
        for controller in lingering.values { controller.teardown() }
        lingering.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
    }

    private func start(_ tracker: ScriptTracker, host: any AdRenderingHost) {
        let entryID = tracker.entryID
        let controller = CreativeWebController(host: host)
        running[entryID] = controller
        controller.onEvent = { [weak self] event in
            switch event {
            case .loaded: self?.finish(entryID, status: 200, error: nil)
            case let .failed(message): self?.finish(entryID, status: nil, error: message)
            default: break
            }
        }
        host.rendererLog(RendererLogEntry(.html, .info, "Injecting script tracker \(tracker.request.trigger): \(tracker.request.url.prefix(200))"))
        controller.load(CreativeWebController.Content(document: ScriptTrackerDocument.document(for: tracker.request), mraid: nil,
                                                      blocksNetwork: false, disableScroll: true, networkParentID: entryID,
                                                      source: tracker.request.source, baseURL: CreativeWebController.trackerBaseURL))
        let timeout = Self.timeout
        timeouts[entryID] = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(entryID, status: nil, error: "The script tracker did not finish loading in time")
        }
    }

    private func finish(_ entryID: UUID, status: Int?, error: String?) {
        guard let controller = running.removeValue(forKey: entryID) else { return }
        timeouts.removeValue(forKey: entryID)?.cancel()
        host?.monitor.finishRendererLoad(entryID, status: status, error: error)
        let key = ObjectIdentifier(controller)
        lingering[key] = controller
        let linger = Self.linger
        Task { [weak self] in
            try? await Task.sleep(for: linger)
            self?.lingering.removeValue(forKey: key)?.teardown()
        }
    }
}

/// Runs the script trackers the host hands over, for as long as the ad is on screen.
private struct ScriptTrackerRunner: ViewModifier {
    let host: any AdRenderingHost
    @State private var injector: ScriptTrackerInjector?

    func body(content: Content) -> some View {
        // Observable on the session: a tracker listed after `.rendered` updates this view. When Real mode ends (and on
        // every new render or reset) the session tears every injector it adopted down in that same turn, linger
        // included, so nothing more reaches the network (safety review); emptying the list here is the backstop.
        let trackers = host.scriptTrackers
        let real = host.monitor.mode == .real
        content
            .onChange(of: trackers, initial: true) { _, current in
                guard real, !current.isEmpty else {
                    injector?.teardown()
                    injector = nil
                    return
                }
                // The session may have torn the last one down already (Real mode ended, then a new render).
                let active = injector.flatMap { $0.isTornDown ? nil : $0 } ?? ScriptTrackerInjector(host: host)
                injector = active
                active.inject(current)
            }
            .onChange(of: real) { _, isReal in
                guard !isReal else { return }
                injector?.teardown()
                injector = nil
            }
            .onDisappear {
                injector?.teardown()
                injector = nil
            }
    }
}

extension View {
    func scriptTrackers(host: any AdRenderingHost) -> some View {
        modifier(ScriptTrackerRunner(host: host))
    }
}
