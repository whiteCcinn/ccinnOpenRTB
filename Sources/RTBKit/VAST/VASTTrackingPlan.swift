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
/// | `.companionView(i, c)` (wrappers) | the matching tracking companions of every wrapper above, outermost first, before the companion's own |
/// | `.companionClick(i, c)` | wrapper and own CompanionClickTracking, then a navigation to CompanionClickThrough only when `playerOpensClickThrough` (an image StaticResource; none on CTV); script, HTML and iframe companions open their own click-through |
/// | `.error(code, i)` | ad i's Error URLs with `[ERRORCODE]` = code; `nil`: `failureErrorURLs` when no ad resolved, else every ad's |
/// | anything else | nothing (display and Native events belong to `TrackingPlan`) |
///
/// One user action, one `trigger` (decisions "Network relationships": "Siblings from one user action share a trigger"):
/// every request of one event carries the action's name (`VAST creativeView`, `VAST click`, `VAST companion click`,
/// `VAST playerExpand`, …), plus ` (ad i of n)` in a pod. `category` separates trackers from the navigation, and the
/// element path in `source` tells which tracker it is. A chain-wide `.error(code, adIndex: nil)` is one action across the
/// pod, so it has no ad position.
///
/// Indices come from renderers and are never trusted: an `adIndex` or `companionIndex` outside the resolution (negative,
/// `count`, `Int.max`, …) plans nothing.
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

    /// `MacroContext.custom` keys of the ad-level VAST macros the plan fills (VAST 4.1 / 4.2, all "Contexts: All tracking
    /// pixels"). `[ADCATEGORIES]` is not one of them: it is a VAST request macro, "List of desired ad categories" (§6.3).
    enum Macro {
        /// §6.7 `[PODSEQUENCE]`: "The value of the sequence attribute on the <Ad> that is currently playing".
        static let podSequence = "[PODSEQUENCE]"
        /// §6.7 `[ADSERVINGID]`: "The value of the <AdServingId> for the currently playing ad".
        static let adServingID = "[ADSERVINGID]"
        /// §6.3 `[UNIVERSALADID]`: "registryID idvalue - with a space separating registryID and value"; 4.2: "Multiple
        /// UniversalAdIDs can be supported with a comma separating them". A list: set in `customLists`.
        static let universalAdID = "[UNIVERSALADID]"
        /// §6.3 `[ADTYPE]`: "video, audio, or hybrid, as defined in the adType attribute of the VAST <Ad> element".
        static let adType = "[ADTYPE]"
    }

    /// `[REASON]` for `verificationNotExecuted`: 2 = verification not supported (the simulator never runs the scripts).
    static let verificationNotSupported = 2

    // MARK: Video events

    func videoEvent(_ event: VASTEvent, adIndex: Int) -> [TrackerRequest] {
        guard let ad = ad(at: adIndex) else { return [] }
        let lineage = VASTLineage(origin: ad.origin, chain: vast.chain)
        let adContext = adContext(ad, lineage: lineage)
        // The reported action names every request, also a tracker written with an equivalent spelling (`fullscreen` for
        // `playerExpand`): its own spelling stays in the element path.
        let trigger = "VAST " + event.vastLabel
        var requests: [TrackerRequest] = []

        if event == .creativeView {
            requests += Self.attributed(ad.impressions, lineage, \.impressions).map { url, layer in
                make(url, .impression, trigger, adIndex, layer, "Impression", context: adContext)
            }
        }
        let trackings = Self.attributed(ad.trackingEvents, lineage, \.linearTrackings)
        for (tracking, layer) in trackings where Self.event(tracking.event, answers: event) {
            requests.append(make(tracking.url, .event, trigger, adIndex, layer, "TrackingEvents/" + tracking.event.vastLabel, context: adContext))
        }
        if event == .creativeView {
            requests += verificationNotExecuted(ad, adIndex: adIndex, lineage: lineage, adContext: adContext, trigger: trigger)
        }
        return requests
    }

    private func verificationNotExecuted(_ ad: ResolvedVASTAd, adIndex: Int, lineage: VASTLineage?, adContext: MacroContext,
                                         trigger: String) -> [TrackerRequest] {
        var reasonContext = adContext
        reasonContext.reason = Self.verificationNotSupported
        return Self.attributed(ad.verifications, lineage, \.verifications).flatMap { verification, layer in
            verification.trackingEvents
                .filter { $0.event.vastName == VASTSpecRules.verificationNotExecuted }
                .map { tracking in
                    let vendor = verification.vendor.map { " '\($0)'" } ?? ""
                    return make(tracking.url, .verification, trigger, adIndex, layer,
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
        let adContext = adContext(ad, lineage: lineage)
        var requests = Self.attributed(ad.clickTrackings, lineage, \.linearClickTrackings).map { url, layer in
            make(url, .click, "VAST click", adIndex, layer, "VideoClicks/ClickTracking", context: adContext)
        }
        if canNavigate, let clickThrough = ad.inline.playedLinear?.clickThrough {
            requests.append(make(clickThrough, .navigation, "VAST click", adIndex, lineage?.inlineLayer, "VideoClicks/ClickThrough",
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
        let adContext = adContext(ad, lineage: lineage)
        return urls.map { url, layer in
            make(url, .viewability, "VAST " + element, adIndex, layer, "ViewableImpression/" + element, context: adContext)
        }
    }

    // MARK: Companions

    /// The companion's `creativeView`, after the matching tracking companions of every wrapper above it (outermost first;
    /// `VASTCompanionMatch`). Identical URLs fire once.
    func companionView(adIndex: Int, companionIndex: Int) -> [TrackerRequest] {
        guard let target = companionTarget(adIndex: adIndex, companionIndex: companionIndex) else { return [] }
        let views = target.layered { companion in companion.trackingEvents.filter { $0.event == .creativeView }.map(\.url) }
        return views.map { url, layer, element in
            make(url, .event, "VAST companion creativeView", adIndex, layer, element + "/creativeView", context: target.context)
        }
    }

    /// The CompanionClickTracking of the matching wrapper companions (outermost first) and of the companion, then the
    /// navigation to its CompanionClickThrough, only when `playerOpensClickThrough` (an image StaticResource) and the device
    /// can open it.
    func companionClick(adIndex: Int, companionIndex: Int) -> [TrackerRequest] {
        guard let target = companionTarget(adIndex: adIndex, companionIndex: companionIndex) else { return [] }
        var requests = target.layered(\.clickTrackings).map { url, layer, element in
            make(url, .click, "VAST companion click", adIndex, layer, element + "/CompanionClickTracking", context: target.context)
        }
        // Exactly one navigation per click (decisions "Renderer contract rulings"): script, HTML and iframe companions
        // navigate themselves, and the renderer reports it.
        let companion = target.companion
        if canNavigate, companion.playerOpensClickThrough, let clickThrough = companion.clickThrough {
            requests.append(make(clickThrough, .navigation, "VAST companion click", adIndex, target.lineage?.inlineLayer,
                                 target.element + "/CompanionClickThrough", context: target.context))
        }
        return requests
    }

    /// A companion of a resolved ad, with what its requests need.
    private struct CompanionTarget {
        let companion: VASTCompanion
        let lineage: VASTLineage?
        /// `Companion 2 id="c"`.
        let element: String
        let context: MacroContext

        /// `part` of every matching wrapper companion (outermost wrapper first), then of the companion itself, each URL with
        /// its layer and element label; a URL already listed is dropped.
        func layered(_ part: (VASTCompanion) -> [String]) -> [(url: String, layer: VASTLayer?, element: String)] {
            var entries: [(url: String, layer: VASTLayer?, element: String)] = []
            for layer in lineage?.layers.dropLast() ?? [] {
                let candidates = layer.wrapperCompanions
                for index in VASTCompanionMatch.wrapperCompanionIndices(for: companion, in: candidates) {
                    entries += part(candidates[index]).map { (url: $0, layer: layer, element: VASTLabel.companion(candidates[index], index: index)) }
                }
            }
            entries += part(companion).map { (url: $0, layer: lineage?.inlineLayer, element: element) }
            var seen = Set<String>()
            return entries.filter { seen.insert($0.url).inserted }
        }
    }

    /// `companionIndex` indexes `ads[adIndex].inline.creatives.flatMap(\.companions)`; `nil` outside it.
    private func companionTarget(adIndex: Int, companionIndex: Int) -> CompanionTarget? {
        guard let ad = ad(at: adIndex), let (creative, companion) = Self.companion(at: companionIndex, in: ad.inline) else { return nil }
        let lineage = VASTLineage(origin: ad.origin, chain: vast.chain)
        return CompanionTarget(companion: companion, lineage: lineage, element: VASTLabel.companion(companion, index: companionIndex),
                               context: adContext(ad, lineage: lineage, creative: creative))
    }

    /// The creative and companion at a flattened companion index. Total: any `index` outside the companions is `nil`.
    private static func companion(at index: Int, in inline: VASTInline) -> (VASTCreative, VASTCompanion)? {
        guard index >= 0 else { return nil }
        var remaining = index
        for creative in inline.creatives {
            if remaining < creative.companions.count { return (creative, creative.companions[remaining]) }
            remaining -= creative.companions.count
        }
        return nil
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
        // One action across the pod: no ad position in the trigger.
        return vast.ads.enumerated().flatMap { adErrors($0.element, adIndex: $0.offset, code: code, podPositionInTrigger: false) }
    }

    /// The Error URLs of a pod slot or buffet ad that failed during resolution, with its code and slot sequence.
    func failureRequests(_ failure: VASTAdFailure) -> [TrackerRequest] {
        errorRequests(failure.errorURLs, origin: failure.origin, code: failure.code, adIndex: nil,
                      context: Self.withPodSequence(slotSequence(of: failure.origin), context))
    }

    private func adErrors(_ ad: ResolvedVASTAd, adIndex: Int, code: VASTErrorCode, podPositionInTrigger: Bool = true) -> [TrackerRequest] {
        let lineage = VASTLineage(origin: ad.origin, chain: vast.chain)
        let errorContext = Self.withErrorCode(code, adContext(ad, lineage: lineage))
        return Self.attributed(ad.errors, lineage, \.errors).map { url, layer in
            make(url, .error, "VAST error \(code.rawValue)", adIndex, layer, "Error", context: errorContext,
                 podPositionInTrigger: podPositionInTrigger)
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

    /// The macro context of one ad's requests, or of one of its companions' (`companionIndex`); `nil` when an index is out
    /// of range.
    func macroContext(adIndex: Int, companionIndex: Int? = nil) -> MacroContext? {
        if let companionIndex { return companionTarget(adIndex: adIndex, companionIndex: companionIndex)?.context }
        guard let ad = ad(at: adIndex) else { return nil }
        return adContext(ad, lineage: VASTLineage(origin: ad.origin, chain: vast.chain))
    }

    /// The host's context with what the plan knows about the ad that is playing (`Macro`; decisions "VAST macro rulings").
    /// Values the document does not provide are left out, so the expander fills VAST's "unknown" (`-1`, §6.1). `creative`
    /// is the creative a request is about (a companion's); by default, the played Linear's.
    private func adContext(_ ad: ResolvedVASTAd, lineage: VASTLineage?, creative: VASTCreative? = nil) -> MacroContext {
        var adContext = Self.withPodSequence(ad.sequence, context)
        if let adServingID = ad.inline.adServingID { adContext.custom[Macro.adServingID] = adServingID }
        if let adType = Self.adType(of: lineage) { adContext.custom[Macro.adType] = adType }
        if let ids = Self.universalAdIDs(of: creative ?? ad.inline.playedCreative) { adContext.customLists[Macro.universalAdID] = ids }
        return adContext
    }

    /// `registryID idvalue` per `UniversalAdId` (VAST 4.1 §6.3, "with a space separating registryID and value"), one list
    /// item each: VAST 4.2 §6.3 separates several with commas, and §6.1 encodes each value on its own, so they go to
    /// `MacroContext.customLists` (decisions "VAST macro rulings"). `nil` when the creative has none.
    private static func universalAdIDs(of creative: VASTCreative?) -> [String]? {
        guard let ids = creative?.universalAdIDs, !ids.isEmpty else { return nil }
        return ids.map { $0.registry + " " + $0.value }
    }

    /// The InLine `<Ad>`'s `adType`; when absent, `video` for documents of VAST 4.1 and later (§3.3.2: "assumed to be video
    /// if attribute is not present"), unknown before 4.1, which has no such attribute.
    private static func adType(of lineage: VASTLineage?) -> String? {
        guard let inlineLayer = lineage?.inlineLayer else { return nil }
        if let adType = inlineLayer.ad.adType { return adType }
        return VASTSpecVersion.parsingVersion(of: inlineLayer.hop.document?.version) >= .v4_1 ? "video" : nil
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
        adContext.custom[Macro.podSequence] = String(sequence)
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

    /// `podPositionInTrigger`: add ` (ad i of n)` to the trigger in a pod (not for an action that spans the pod).
    private func make(_ template: String, _ category: TrackerCategory, _ trigger: String, _ adIndex: Int, _ layer: VASTLayer?,
                      _ element: String, context: MacroContext, podPositionInTrigger: Bool = true) -> TrackerRequest {
        let documentParts = layer.map { [$0.documentLabel, $0.adLabel] } ?? ["VAST ad " + VASTLabel.ordinal(adIndex)]
        return request(template, category, trigger, adIndex: podPositionInTrigger ? adIndex : nil, path: documentParts + [element],
                       parentID: layer?.hop.requestID, context: context)
    }

    private func request(_ template: String, _ category: TrackerCategory, _ trigger: String, adIndex: Int?, path: [String], parentID: UUID?,
                         context: MacroContext) -> TrackerRequest {
        let expanded = MacroExpander.expand(template, context: context)
        let podSuffix = vast.ads.count > 1 ? adIndex.map { " (ad " + VASTLabel.ordinal($0) + " of \(vast.ads.count))" } ?? "" : ""
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
