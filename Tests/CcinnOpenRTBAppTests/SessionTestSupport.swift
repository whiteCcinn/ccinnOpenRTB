import CcinnOpenRTBKit
import Foundation
import os
import RTBKit
import Testing
@testable import CcinnOpenRTB

extension Duration {
    /// A fake answer held until the test cancels it. The outcome must depend on the cancellation alone: a short delay
    /// (it was 5 s) races the cancel on a starved 3-core CI runner and lets the response through. This only guards
    /// against a hang if cancellation breaks.
    static let heldUntilCancelled = Duration.seconds(60)
}

/// Seconds the tests move by hand.
final class ManualSessionClock: SessionClock {
    private let current = OSAllocatedUnfairLock(initialState: 0.0)
    func now() -> Double { current.withLock { $0 } }
    func set(_ seconds: Double) { current.withLock { $0 = seconds } }
}

/// Records every call the session makes into the kit, and answers with one tracker per event.
final class KitRecorder: Sendable {
    private struct State {
        var events: [AdLifecycleEvent] = []
        var contexts: [MacroContext] = []
        var options: [TrackingPlanOptions] = []
        var resolutions: [VASTSource] = []
        var resolutionRequestCalls = 0
        var parses = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var events: [AdLifecycleEvent] { state.withLockUnchecked { $0.events } }
    var contexts: [MacroContext] { state.withLockUnchecked { $0.contexts } }
    var options: [TrackingPlanOptions] { state.withLockUnchecked { $0.options } }
    var resolutions: [VASTSource] { state.withLockUnchecked { $0.resolutions } }
    var resolutionRequestCalls: Int { state.withLockUnchecked { $0.resolutionRequestCalls } }
    var parses: Int { state.withLockUnchecked { $0.parses } }

    func record(_ event: AdLifecycleEvent, _ context: MacroContext, _ options: TrackingPlanOptions) {
        state.withLockUnchecked {
            $0.events.append(event)
            $0.contexts.append(context)
            $0.options.append(options)
        }
    }

    func recordResolution(_ source: VASTSource) { state.withLockUnchecked { $0.resolutions.append(source) } }
    func recordResolutionRequests() { state.withLockUnchecked { $0.resolutionRequestCalls += 1 } }
    func recordParse() { state.withLockUnchecked { $0.parses += 1 } }
}

/// Lets a test hold VAST resolution until it decides.
final class ResolutionGate: Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
    private let opened = OSAllocatedUnfairLock(initialState: false)

    func wait() async {
        await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
            if opened.withLock({ $0 }) { next.resume(); return }
            continuation.withLock { $0 = next }
        }
    }

    func open() {
        opened.withLock { $0 = true }
        continuation.withLock { pending in
            pending?.resume()
            pending = nil
        }
    }

    var isWaiting: Bool { continuation.withLock { $0 != nil } }
}

enum Fixtures {
    static let winURL = "https://win.dsp.example/w?p=${AUCTION_PRICE}"
    static let billingURL = "https://bill.dsp.example/b?p=${AUCTION_PRICE}"
    static let lossURL = "https://loss.dsp.example/l?r=${AUCTION_LOSS}"

    static func candidate(_ markup: AdMarkup, format: AdFormat = .banner, id: String = "0.0", winURL: String? = Fixtures.winURL,
                          markupURL: String? = nil) -> AdCandidate {
        AdCandidate(id: id, bidID: "bid-\(id)", impID: "1", seat: "seat-a", price: 2.5, size: AdSize(width: 320, height: 50), format: format,
                    markup: markup, markupURL: markupURL, winURL: winURL, billingURL: billingURL, lossURL: lossURL)
    }

    static func input(_ candidates: [AdCandidate], kind: InputKind = .bidResponse(.v2("2.6"))) -> ParsedInput {
        ParsedInput(kind: kind, responseID: "auction-1", candidates: candidates)
    }

    static func vast(ads: Int, failure: VASTErrorCode? = nil) -> ResolvedVAST {
        let ad = ResolvedVASTAd(inline: VASTInline(adSystem: "Acme", impressions: ["https://imp.vast.example/i"]),
                                impressions: ["https://imp.vast.example/i"])
        return ResolvedVAST(ads: Array(repeating: ad, count: ads), failure: failure,
                            issues: [ValidationIssue(.warning, code: "vast.test", message: "from resolution", path: "VAST/Ad[1]")])
    }

    static let native = NativeAd(version: "1.2", assets: [NativeAsset(id: 1, content: .title(text: "Hello"))],
                                 link: AdLink(url: "https://landing.example/", clickTrackers: ["https://click.native.example/c"]),
                                 impressionTrackers: ["https://imp.native.example/i"])

    /// Services that answer `input` for any text, and one tracker per event (two for clicks: tracker + navigation).
    static func services(_ input: ParsedInput, recorder: KitRecorder, native: NativeAd? = Fixtures.native,
                         resolved: ResolvedVAST = Fixtures.vast(ads: 1), gate: ResolutionGate? = nil) -> AdKitServices {
        AdKitServices(
            parseInput: { text, _ in
                recorder.recordParse()
                return text.isEmpty ? ParsedInput(kind: .empty) : input
            },
            parseNative: { _, _ in (native, []) },
            parseVAST: { _ in (VASTDocument(ads: [VASTAd(body: .inline(VASTInline(impressions: ["https://imp.vast.example/i"])))]), []) },
            resolveVAST: { source, _, _, _ in
                recorder.recordResolution(source)
                if let gate { await gate.wait() }
                return resolved
            },
            trackingRequests: { event, candidate, _, _, context, options in
                recorder.record(event, context, options)
                return requests(for: event, candidate: candidate, options: options)
            },
            resolutionRequests: { _, _, source in
                recorder.recordResolutionRequests()
                return [TrackerRequest(category: .error, trigger: "VAST resolution", source: source, template: "https://err.vast.example/e",
                                       url: "https://err.vast.example/e")]
            },
            expand: { template, _ in ExpandedURL(url: template.replacingOccurrences(of: "${AUCTION_PRICE}", with: "2.5")) },
            expandOpenRTB: { template, _ in ExpandedURL(url: template.replacingOccurrences(of: "${AUCTION_PRICE}", with: "2.5")) },
            expandMarkup: { markup, _ in ExpandedURL(url: markup.replacingOccurrences(of: "${AUCTION_PRICE}", with: "2.5")) },
            samples: { [] }
        )
    }

    static func requests(for event: AdLifecycleEvent, candidate: AdCandidate, options: TrackingPlanOptions) -> [TrackerRequest] {
        func request(_ category: TrackerCategory, _ url: String) -> TrackerRequest {
            TrackerRequest(category: category, trigger: event.label, source: "bid \(candidate.id)", template: url, url: url)
        }
        switch event {
        case .won: return options.exchangeSendsWinNotice ? [request(.win, candidate.winURL ?? "https://win.example/")] : []
        case .rendered: return [request(.billing, candidate.billingURL ?? "https://bill.example/"), request(.impression, "https://imp.example/i")]
        case .viewable, .videoViewability: return [request(.viewability, "https://view.example/v")]
        case .video: return [request(.event, "https://event.vast.example/e")]
        case .click, .videoClick, .companionClick, .iconClick:
            return [request(.click, "https://click.example/c"), request(.navigation, "https://landing.example/")]
        case .loss: return [request(.loss, candidate.lossURL ?? "https://loss.example/")]
        case .error: return [request(.error, "https://err.vast.example/e")]
        case .closed, .companionView, .iconView: return [request(.event, "https://event.example/close")]
        }
    }
}

/// A transport that answers configured URLs and counts what reached it.
final class CountingTransport: HTTPTransport {
    private struct State {
        var bodies: [String: String] = [:]
        var prefixBodies: [(prefix: String, body: String)] = []
        var requests: [HTTPRequest] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var requests: [HTTPRequest] { state.withLockUnchecked { $0.requests } }

    func respond(_ url: String, body: String) { state.withLockUnchecked { $0.bodies[url] = body } }

    /// Answers every URL that starts with `prefix` (a URL whose query the player expands at request time).
    func respondByPrefix(_ prefix: String, body: String) { state.withLockUnchecked { $0.prefixBodies.append((prefix, body)) } }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = state.withLockUnchecked { state -> String? in
            state.requests.append(request)
            let url = request.url.absoluteString
            return state.bodies[url] ?? state.prefixBodies.first { url.hasPrefix($0.prefix) }?.body
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/plain"], body: Data((body ?? "").utf8))
    }
}

@MainActor
final class RecordingBrowser: BrowserOpening {
    private(set) var opened: [URL] = []
    /// `false`: no default web browser (nothing opens).
    var hasBrowser = true
    func open(_ url: URL) -> Bool {
        guard hasBrowser else { return false }
        opened.append(url)
        return true
    }
}

@MainActor
struct SessionHarness {
    let session: AdSession
    let recorder: KitRecorder
    let transport: CountingTransport
    let clock: ManualSessionClock
    let browser: RecordingBrowser
    let monitor: NetworkMonitor

    /// - Parameter configure: adjusts the fake kit (for example a tracking plan that returns script trackers).
    init(_ input: ParsedInput, native: NativeAd? = Fixtures.native, resolved: ResolvedVAST = Fixtures.vast(ads: 1), gate: ResolutionGate? = nil,
         opensClickThroughs: Bool = false, configure: (inout AdKitServices) -> Void = { _ in }) {
        recorder = KitRecorder()
        transport = CountingTransport()
        clock = ManualSessionClock()
        browser = RecordingBrowser()
        monitor = NetworkMonitor(transport: transport, publishInterval: .zero)
        var services = Fixtures.services(input, recorder: recorder, native: native, resolved: resolved, gate: gate)
        configure(&services)
        session = AdSession(services: services, monitor: monitor, clock: clock, browser: browser, opensClickThroughs: { opensClickThroughs },
                            parseDebounce: .zero)
    }

    /// Pastes `text` and waits for the parse.
    func paste(_ text: String = "response") async {
        session.responseText = text
        await session.parseNow()
    }

    /// Renders and waits until the render settles (ready, failed, needs Real mode …).
    func renderAndWait() async {
        session.render()
        await waitUntilSettled()
    }

    func waitUntilSettled() async {
        for _ in 0..<2_000 {
            if case .preparing = session.phase { try? await Task.sleep(for: .milliseconds(1)) } else { break }
        }
        await monitor.waitUntilIdle()
    }

    /// Enters Real mode the only way there is: through the confirmation.
    func enterRealMode() {
        session.requestRealMode()
        if let confirmation = session.realModeConfirmation { session.confirmRealMode(confirmation) }
    }

    var categories: [TrackerCategory] { monitor.liveEntries.map(\.category) }
}
