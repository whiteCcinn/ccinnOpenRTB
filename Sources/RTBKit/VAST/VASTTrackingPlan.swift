import Foundation

/// VAST part of the tracking plan (design D7, decisions f4ae447 / 69d7bac). Owner: kit-vast.
///
/// Pure: the same event, resolution and context give the same requests (apart from their random `id`). Every request
/// names its origin document in `source` (`bid 0.0 › VAST hop 2 › InLine Ad[1] 'Title' › Impression`) and has the
/// `requestID` of the hop that delivered that document as `parentID`. Merged lists that were not produced from the chain
/// (a hand-built `ResolvedVASTAd`) are still planned, attributed to the ad without a parent.
///
/// | Event | Requests, in order |
/// |---|---|
/// | `.video(.creativeView, i)` | ad i's Impressions, its `creativeView` Tracking, its `verificationNotExecuted` trackers (`[REASON]` = 2) |
/// | `.video(e, i)` | ad i's Tracking for `e` (`fullscreen` ≡ `playerExpand`, `exitFullscreen` ≡ `playerCollapse`, `close` ≡ `closeLinear`, `acceptInvitation` ≡ `acceptInvitationLinear`; `progress` matches its exact offset) |
/// | `.videoClick(i)` | ad i's ClickTracking, then a navigation to its ClickThrough (none when the device cannot open click-throughs) |
/// | `.videoViewability(v, i)` | ad i's `Viewable` / `NotViewable` / `ViewUndetermined` |
/// | `.companionView(i, c)` | the companion's `creativeView` Tracking |
/// | `.companionClick(i, c)` | its CompanionClickTracking, then a navigation to CompanionClickThrough (none on CTV) |
/// | `.error(code, i)` | ad i's Error URLs with `[ERRORCODE]` = code; `nil`: `failureErrorURLs` when no ad resolved, else every ad's |
/// | anything else | nothing (display and Native events belong to `TrackingPlan`) |
///
/// Resolution-time failures (`ResolvedVAST.adFailures`) are planned by `resolutionRequests` (VASTResolutionPlan.swift).
///
/// Macros: the plan sets what it knows about the ad on top of the host's context: `[ERRORCODE]`, `[REASON]` (2 for
/// `verificationNotExecuted`) and `[PODSEQUENCE]` (the `sequence` of the pod slot the ad plays in). Playback values
/// (`[ADPLAYHEAD]`, `[ASSETURI]`, `[PLAYERSIZE]`, …) come from the host's context.
public enum VASTTrackingPlan {
    public static func requests(for event: AdLifecycleEvent, vast: ResolvedVAST, candidate: AdCandidate?, context: MacroContext,
                                source: String) -> [TrackerRequest] {
        let planner = VASTPlanner(vast: vast, context: context, source: source)
        switch event {
        case let .video(videoEvent, adIndex):
            return planner.videoEvent(videoEvent, adIndex: adIndex)
        case let .videoClick(adIndex):
            return planner.videoClick(adIndex: adIndex)
        case let .videoViewability(outcome, adIndex):
            return planner.viewability(outcome, adIndex: adIndex)
        case let .companionView(adIndex, companionIndex):
            return planner.companionView(adIndex: adIndex, companionIndex: companionIndex)
        case let .companionClick(adIndex, companionIndex):
            return planner.companionClick(adIndex: adIndex, companionIndex: companionIndex)
        case let .error(code, adIndex):
            return planner.error(code, adIndex: adIndex)
        case .won, .rendered, .viewable, .click, .closed, .loss:
            return []
        }
    }
}

// MARK: - Planner

/// Builds the requests of one event for one resolution. Internal so that `resolutionRequests` (its own file) shares it.
struct VASTPlanner {
    let vast: ResolvedVAST
    let context: MacroContext
    let source: String

    /// `custom` key of `[PODSEQUENCE]` (VAST 4.1: "the value of the sequence attribute on the Ad that was played").
    static let podSequenceMacro = "[PODSEQUENCE]"

    /// `[REASON]` for `verificationNotExecuted`: 2 = verification not supported (the simulator never runs the scripts).
    static let verificationNotSupported = 2

    // MARK: Video events

    func videoEvent(_ event: VASTEvent, adIndex: Int) -> [TrackerRequest] {
        guard let ad = ad(at: adIndex) else { return [] }
        let lineage = VASTLineage(origin: ad.origin, chain: vast.chain)
        let adContext = adContext(ad)
        var requests: [TrackerRequest] = []

        if event == .creativeView {
            requests += Self.attributed(ad.impressions, lineage, \.impressions).map { url, layer in
                make(url, .impression, "VAST impression", adIndex, layer, "Impression", context: adContext)
            }
        }
        let trackings = Self.attributed(ad.trackingEvents, lineage, \.linearTrackings)
        for (tracking, layer) in trackings where Self.event(tracking.event, answers: event) {
            requests.append(make(tracking.url, .event, "VAST " + tracking.event.vastLabel, adIndex, layer,
                                 "TrackingEvents/" + tracking.event.vastLabel, context: adContext))
        }
        if event == .creativeView {
            requests += verificationNotExecuted(ad, adIndex: adIndex, lineage: lineage, adContext: adContext)
        }
        return requests
    }

    private func verificationNotExecuted(_ ad: ResolvedVASTAd, adIndex: Int, lineage: VASTLineage?, adContext: MacroContext) -> [TrackerRequest] {
        var reasonContext = adContext
        reasonContext.reason = Self.verificationNotSupported
        return Self.attributed(ad.verifications, lineage, \.verifications).flatMap { verification, layer in
            verification.trackingEvents
                .filter { $0.event.vastName == VASTSpecRules.verificationNotExecuted }
                .map { tracking in
                    let vendor = verification.vendor.map { " '\($0)'" } ?? ""
                    return make(tracking.url, .verification, "VAST verificationNotExecuted (\(Self.verificationNotSupported))", adIndex, layer,
                                "AdVerifications/Verification\(vendor)/verificationNotExecuted", context: reasonContext)
                }
        }
    }

    /// Whether a tracking element for `tracked` fires when the player reports `reported`. VAST 4 renamed some player
    /// actions; a document of any version fires on the same action. `progress` fires for its exact offset only (the
    /// player reports each offset of the ad's trackers once), so a tracker never fires twice.
    static func event(_ tracked: VASTEvent, answers reported: VASTEvent) -> Bool {
        tracked == reported || equivalenceClass(tracked).map { $0.contains(reported) } ?? false
    }

    private static func equivalenceClass(_ event: VASTEvent) -> Set<VASTEvent>? {
        let classes: [Set<VASTEvent>] = [
            [.fullscreen, .playerExpand],
            [.exitFullscreen, .playerCollapse],
            [.close, .closeLinear],
            [.acceptInvitation, .acceptInvitationLinear],
        ]
        return classes.first { $0.contains(event) }
    }

    // MARK: Clicks

    func videoClick(adIndex: Int) -> [TrackerRequest] {
        guard let ad = ad(at: adIndex) else { return [] }
        let lineage = VASTLineage(origin: ad.origin, chain: vast.chain)
        let adContext = adContext(ad)
        var requests = Self.attributed(ad.clickTrackings, lineage, \.linearClickTrackings).map { url, layer in
            make(url, .click, "VAST click", adIndex, layer, "VideoClicks/ClickTracking", context: adContext)
        }
        if canNavigate, let clickThrough = ad.inline.playedLinear?.clickThrough {
            requests.append(make(clickThrough, .navigation, "VAST click-through", adIndex, lineage?.inlineLayer, "VideoClicks/ClickThrough",
                                 context: adContext))
        }
        return requests
    }

    // MARK: Viewability

    func viewability(_ outcome: VideoViewability, adIndex: Int) -> [TrackerRequest] {
        guard let ad = ad(at: adIndex) else { return [] }
        let lineage = VASTLineage(origin: ad.origin, chain: vast.chain)
        let element: String
        let part: (VASTViewableImpression) -> [String]
        switch outcome {
        case .viewable: (element, part) = ("Viewable", { $0.viewable })
        case .notViewable: (element, part) = ("NotViewable", { $0.notViewable })
        case .undetermined: (element, part) = ("ViewUndetermined", { $0.viewUndetermined })
        }
        let urls = Self.attributed(part(ad.viewableImpression), lineage) { body in body.viewableImpression.map(part) ?? [] }
        let adContext = adContext(ad)
        return urls.map { url, layer in
            make(url, .viewability, "VAST " + element, adIndex, layer, "ViewableImpression/" + element, context: adContext)
        }
    }

    // MARK: Companions

    func companionView(adIndex: Int, companionIndex: Int) -> [TrackerRequest] {
        guard let (ad, companion) = companion(adIndex: adIndex, companionIndex: companionIndex) else { return [] }
        let layer = VASTLineage(origin: ad.origin, chain: vast.chain)?.inlineLayer
        let adContext = adContext(ad)
        return companion.trackingEvents.filter { $0.event == .creativeView }.map { tracking in
            make(tracking.url, .event, "VAST companion creativeView", adIndex, layer,
                 Self.companionElement(companion, companionIndex) + "/creativeView", context: adContext)
        }
    }

    func companionClick(adIndex: Int, companionIndex: Int) -> [TrackerRequest] {
        guard let (ad, companion) = companion(adIndex: adIndex, companionIndex: companionIndex) else { return [] }
        let layer = VASTLineage(origin: ad.origin, chain: vast.chain)?.inlineLayer
        let element = Self.companionElement(companion, companionIndex)
        let adContext = adContext(ad)
        var requests = companion.clickTrackings.map { url in
            make(url, .click, "VAST companion click", adIndex, layer, element + "/CompanionClickTracking", context: adContext)
        }
        if canNavigate, let clickThrough = companion.clickThrough {
            requests.append(make(clickThrough, .navigation, "VAST companion click-through", adIndex, layer, element + "/CompanionClickThrough",
                                 context: adContext))
        }
        return requests
    }

    private func companion(adIndex: Int, companionIndex: Int) -> (ResolvedVASTAd, VASTCompanion)? {
        guard let ad = ad(at: adIndex) else { return nil }
        let companions = ad.inline.creatives.flatMap(\.companions)
        guard companions.indices.contains(companionIndex) else { return nil }
        return (ad, companions[companionIndex])
    }

    private static func companionElement(_ companion: VASTCompanion, _ index: Int) -> String {
        "Companion \(index + 1)" + (companion.id.map { " id=\"\($0)\"" } ?? "")
    }

    // MARK: Errors

    func error(_ code: VASTErrorCode, adIndex: Int?) -> [TrackerRequest] {
        if let adIndex {
            guard let ad = ad(at: adIndex) else { return [] }
            return adErrors(ad, adIndex: adIndex, code: code)
        }
        guard !vast.ads.isEmpty else {
            return errorRequests(vast.failureErrorURLs, origin: nil, code: code, adIndex: nil, context: context)
        }
        return vast.ads.enumerated().flatMap { adErrors($0.element, adIndex: $0.offset, code: code) }
    }

    /// The Error URLs of a pod slot or buffet ad that failed during resolution, with its code and slot sequence.
    func failureRequests(_ failure: VASTAdFailure) -> [TrackerRequest] {
        errorRequests(failure.errorURLs, origin: failure.origin, code: failure.code, adIndex: nil,
                      context: Self.withPodSequence(slotSequence(of: failure.origin), context))
    }

    private func adErrors(_ ad: ResolvedVASTAd, adIndex: Int, code: VASTErrorCode) -> [TrackerRequest] {
        let lineage = VASTLineage(origin: ad.origin, chain: vast.chain)
        let errorContext = Self.withErrorCode(code, adContext(ad))
        return Self.attributed(ad.errors, lineage, \.errors).map { url, layer in
            make(url, .error, "VAST error \(code.rawValue)", adIndex, layer, "Error", context: errorContext)
        }
    }

    /// Error URLs of a failed chain, attributed by finding each URL in the documents it passed through (outermost first,
    /// then the root `<Error>` of a no-ad response). Without an origin every document of the chain is searched.
    private func errorRequests(_ urls: [String], origin: [VASTAdOrigin]?, code: VASTErrorCode, adIndex: Int?,
                               context: MacroContext) -> [TrackerRequest] {
        let sources = VASTErrorSources(chain: vast.chain, origin: origin)
        let errorContext = Self.withErrorCode(code, context)
        return sources.attribute(urls).map { url, location in
            let hop = location.flatMap { vast.chain.indices.contains($0.hop) ? vast.chain[$0.hop] : nil }
            return request(url, .error, "VAST error \(code.rawValue)", adIndex: adIndex, path: location?.path ?? ["VAST", "Error"],
                           parentID: hop?.requestID, context: errorContext)
        }
    }

    // MARK: Macro context

    /// The host's context with what the plan knows about `ad`: its pod slot's `[PODSEQUENCE]`.
    private func adContext(_ ad: ResolvedVASTAd) -> MacroContext {
        Self.withPodSequence(ad.sequence, context)
    }

    /// The `sequence` of the pod slot a chain of documents started in (the outermost ad that has one).
    private func slotSequence(of origin: [VASTAdOrigin]) -> Int? {
        origin.lazy.compactMap { item -> Int? in
            guard vast.chain.indices.contains(item.hop), let ads = self.vast.chain[item.hop].document?.ads, ads.indices.contains(item.ad) else {
                return nil
            }
            return ads[item.ad].sequence
        }.first
    }

    private static func withPodSequence(_ sequence: Int?, _ context: MacroContext) -> MacroContext {
        guard let sequence else { return context }
        var adContext = context
        adContext.custom[podSequenceMacro] = String(sequence)
        return adContext
    }

    private static func withErrorCode(_ code: VASTErrorCode, _ context: MacroContext) -> MacroContext {
        var errorContext = context
        errorContext.errorCode = code.rawValue
        return errorContext
    }

    // MARK: Building requests

    private var canNavigate: Bool {
        context.device?.supportsClickThrough ?? true
    }

    private func ad(at index: Int) -> ResolvedVASTAd? {
        vast.ads.indices.contains(index) ? vast.ads[index] : nil
    }

    /// `merged` with each value's layer (see `VASTLineage.attribute`).
    private static func attributed<Value: Equatable>(_ merged: [Value], _ lineage: VASTLineage?,
                                                     _ part: (VASTAd.Body) -> [Value]) -> [(value: Value, layer: VASTLayer?)] {
        guard let lineage else { return merged.map { (value: $0, layer: nil) } }
        return lineage.attribute(merged, part: part)
    }

    private func make(_ template: String, _ category: TrackerCategory, _ trigger: String, _ adIndex: Int, _ layer: VASTLayer?,
                      _ element: String, context: MacroContext) -> TrackerRequest {
        let documentParts = layer.map { [$0.documentLabel, $0.adLabel] } ?? ["VAST ad \(adIndex + 1)"]
        return request(template, category, trigger, adIndex: adIndex, path: documentParts + [element], parentID: layer?.hop.requestID,
                       context: context)
    }

    private func request(_ template: String, _ category: TrackerCategory, _ trigger: String, adIndex: Int?, path: [String], parentID: UUID?,
                         context: MacroContext) -> TrackerRequest {
        let expanded = MacroExpander.expand(template, context: context)
        let podSuffix = vast.ads.count > 1 ? adIndex.map { " (ad \($0 + 1) of \(vast.ads.count))" } ?? "" : ""
        let sourcePath = ([source] + path).filter { !$0.isEmpty }.joined(separator: " › ")
        return TrackerRequest(parentID: parentID, category: category, trigger: trigger + podSuffix, source: sourcePath, template: template,
                              url: expanded.url, replacedMacros: expanded.replaced, unknownMacros: expanded.unknown)
    }
}

// MARK: - Error URL attribution

/// Where the Error URLs of a failed chain come from.
private struct VASTErrorSources {
    struct Location {
        var hop: Int
        /// `[VAST hop 1, Wrapper Ad[1], Error]`, or `[VAST hop 2, VAST/Error]` for a root `<Error>`.
        var path: [String]
    }

    private var candidates: [(url: String, location: Location)] = []

    init(chain: [VASTHop], origin: [VASTAdOrigin]?) {
        if let origin, !origin.isEmpty {
            for item in origin {
                guard chain.indices.contains(item.hop), let document = chain[item.hop].document, document.ads.indices.contains(item.ad) else {
                    continue
                }
                let layer = VASTLayer(origin: item, hop: chain[item.hop], ad: document.ads[item.ad])
                add(document.ads[item.ad].body.errors, Location(hop: item.hop, path: [layer.documentLabel, layer.adLabel, "Error"]))
            }
            // A no-ad response fetched by the last wrapper contributes its root <Error>.
            if let last = origin.last {
                for (index, hop) in chain.enumerated() where hop.parent == last {
                    addRootErrors(of: hop, index: index)
                }
            }
        } else {
            for (index, hop) in chain.enumerated() {
                addRootErrors(of: hop, index: index)
                guard let document = hop.document else { continue }
                for (adIndex, ad) in document.ads.enumerated() {
                    let layer = VASTLayer(origin: VASTAdOrigin(hop: index, ad: adIndex), hop: hop, ad: ad)
                    add(ad.body.errors, Location(hop: index, path: [layer.documentLabel, layer.adLabel, "Error"]))
                }
            }
        }
    }

    private mutating func addRootErrors(of hop: VASTHop, index: Int) {
        guard let document = hop.document else { return }
        let label = index == 0 && hop.url == nil ? "VAST" : "VAST hop \(index)"
        add(document.errors, Location(hop: index, path: [label, "VAST/Error"]))
    }

    private mutating func add(_ urls: [String], _ location: Location) {
        candidates += urls.map { (url: $0, location: location) }
    }

    /// Each URL with the first unused candidate that matches it, searching forward from the previous match (the URLs
    /// are outermost first, like the candidates); `nil` when not found.
    func attribute(_ urls: [String]) -> [(url: String, location: Location?)] {
        var used = Set<Int>()
        var cursor = 0
        return urls.map { url in
            let match = (cursor..<candidates.count).first { !used.contains($0) && candidates[$0].url == url }
                ?? candidates.indices.first { !used.contains($0) && candidates[$0].url == url }
            guard let match else { return (url: url, location: nil) }
            used.insert(match)
            cursor = match + 1
            return (url: url, location: candidates[match].location)
        }
    }
}
