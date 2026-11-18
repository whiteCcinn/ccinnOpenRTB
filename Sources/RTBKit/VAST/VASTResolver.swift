import Foundation

/// Follows wrapper chains and merges trackers (design D6). Owner: kit-vast.
///
/// Rules (IAB VAST 2.0–4.2):
/// - **Pods.** Ads with `sequence` form a pod and play in sequence order (equal values keep document order). Ads without
///   one form the buffet. With a pod, the buffet is used only when no pod ad could be resolved, or to replace a wrapper
///   slot with `fallbackOnNoAd="true"` whose response had no ad. Without a pod, the first buffet ad that resolves plays.
/// - **Wrappers.** A wrapper is followed through its `VASTAdTagURI`. With `allowMultipleAds="false"` (the default) only
///   the first stand-alone ad of the response is used; with `true` the response may be a pod. With
///   `followAdditionalWrappers="false"` wrappers in the response are ignored.
/// - **Blocked categories.** An InLine ad whose `<Category>` a wrapper above lists in `BlockedAdCategories` (VAST 4.1
///   §3.19.2; same code, same authority when both name one) is not used: it fails with 205, its Error URLs included.
///   Without any `<Category>` it plays, with a warning (players that require categories use 204).
/// - **Errors.** At most `maxDepth` wrappers are followed in a chain; the next one fails with 302 without being fetched.
///   A fetch that fails is 301. A response that is not XML is 100; XML that is not VAST is 101. An empty response, or
///   one with no usable ad, is 303, and a no-ad response's root `<Error>` URLs join the chain's. A wrapper without a
///   usable `VASTAdTagURI` is 300. Every Error URL of the failed chain (outermost first) is reported with the code.
/// - **Merging.** Trackers are merged outermost wrapper → inner wrappers → inline ad, per kind: Impression, Error, linear
///   Tracking, ClickTracking, ViewableImpression and AdVerifications. Each document layer's trackers are stored once and
///   shared by every ad below it (`ResolvedVASTAd`'s lists are views), so memory stays linear in the input.
/// - **Tracker budget.** The resolution materialises at most `maxMergedTrackers` merged tracker entries in total (each
///   resolved ad's merged lists and wrapper companion tracking, each failure's Error URLs). Reaching it stops the
///   resolution with a `vast.trackers.budget` error: nothing more is fetched, the ads resolved so far play, and the rest
///   are dropped without Error URLs; with no ad left the failure is 302 (a limit "defined by the media player").
/// - **Failures.** The first failure of an unplayable response is `failure`; every other failed attempt is an
///   `adFailures` entry, so each Error URL is reported exactly once.
/// - **Requests.** Fetches run one at a time in play order, so the chain and the network monitor are deterministic. Each
///   fetch is linked to the request that delivered the wrapper asking for it (`VASTHop.requestID`).
/// - **Macros by origin.** Only the exchange substitutes OpenRTB `${…}`, and only in the bid's own `adm` (OpenRTB 2.6
///   §4.4): a document a request delivered (the win notice's markup, a VAST tag URL or AdCOM `curl`, every wrapper hop)
///   that still carries `${…}` gets one `vast.macro.openrtb.unsubstituted` warning, at its first such element.
public struct VASTResolver: Sendable {
    public var fetcher: any VASTFetcher
    public var maxDepth: Int
    /// `imp.secure = 1`: non-HTTPS URLs are warnings instead of notes.
    public var requireSecure: Bool
    /// When set, VAST macros in http(s) request URIs — a Wrapper's `VASTAdTagURI`, a pasted or AdCOM `curl` tag URL — are
    /// expanded before fetching, as a player does (VAST 4.1 §6.1/§6.2: `[CACHEBUSTING]`, `[TIMESTAMP]`, `[PLAYERSIZE]`, …).
    /// Only VAST `[…]` macros: OpenRTB `${…}` is the exchange's and stays literal. `data:` URIs are never expanded: their
    /// payload is a VAST document with its own macros. `nil`: URIs are requested as written. Each hop keeps both forms
    /// (`VASTHop.template`, `VASTHop.url`), and the fetcher receives both (`fetchVAST(_:template:parentRequestID:)`).
    public var macroContext: MacroContext?
    /// Upper bound on fetches for one resolution (pods of wrappers fan out); further wrappers fail with 302.
    public var maxFetches: Int
    /// Upper bound on merged tracker entries for one resolution (see "Tracker budget").
    public var maxMergedTrackers: Int

    /// 50,000 merged entries: two orders of magnitude above a real pod (10 ads × 5 wrappers × ~30 trackers ≈ 1,500), and
    /// small enough that planning every event of every ad stays instant.
    public static let defaultMaxMergedTrackers = 50_000

    public init(fetcher: any VASTFetcher, maxDepth: Int = 5, requireSecure: Bool = false, macroContext: MacroContext? = nil,
                maxFetches: Int = 64, maxMergedTrackers: Int = defaultMaxMergedTrackers) {
        self.fetcher = fetcher
        self.maxDepth = maxDepth
        self.requireSecure = requireSecure
        self.macroContext = macroContext
        self.maxFetches = maxFetches
        self.maxMergedTrackers = maxMergedTrackers
    }

    /// `parentRequestID` is the request that delivered the markup: for `.url` sources the first fetch is linked to it; for
    /// `.xml` sources (e.g. markup from the win notice) it becomes the first hop's `requestID`, the parent of its
    /// trackers and of its wrapper fetch.
    public func resolve(_ source: VASTSource, parentRequestID: UUID? = nil) async -> ResolvedVAST {
        var run = VASTResolution(resolver: self)
        return await run.resolve(source, parentRequestID: parentRequestID)
    }
}

// MARK: - One resolution

/// The mutable state of one `resolve` call. Used by one task only.
private struct VASTResolution {
    let resolver: VASTResolver
    var chain: [VASTHop] = []
    var issues: [ValidationIssue] = []
    var adFailures: [VASTAdFailure] = []
    var fetchCount = 0
    /// Merged tracker entries materialised so far (`VASTResolver.maxMergedTrackers`).
    var mergedTrackerCount = 0
    var budgetExhausted = false

    init(resolver: VASTResolver) {
        self.resolver = resolver
    }

    mutating func resolve(_ source: VASTSource, parentRequestID: UUID?) async -> ResolvedVAST {
        let parsed: ParsedBody
        switch source {
        case let .xml(xml):
            chain.append(VASTHop(requestID: parentRequestID))
            // With a parent, a request (the win notice, `curl`) delivered the markup: the exchange never substituted it.
            parsed = parse(xml, hop: 0, served: parentRequestID != nil)
        case let .url(rawURL):
            let template = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = expandedTagURI(template)
            fetchCount += 1
            do {
                let response = try await resolver.fetcher.fetchVAST(url, template: template, parentRequestID: parentRequestID)
                chain.append(VASTHop(url: url, requestID: response.requestID, template: template))
                parsed = parse(response.body, hop: 0, served: true)
            } catch {
                chain.append(VASTHop(url: url, error: .wrapperTimeout, template: template))
                report(.error, "vast.tag.fetch.failed", "The VAST tag could not be loaded: \(Self.describe(error)) (VAST error 301).", "VAST")
                return finish(.failed(Failure(code: .wrapperTimeout)))
            }
        }

        switch parsed {
        case let .failed(code):
            chain[0].error = code
            return finish(.failed(Failure(code: code)))
        case let .document(document):
            chain[0].document = document
            // Resolve first, then finish: `finish(await …)` would load `self` (and its chain) before the call mutates it.
            let outcome = await resolveDocument(document, hop: 0, trail: Trail(), policy: .player)
            if case let .resolved(ads) = outcome { reportUnmatchedWrapperCompanions(ads) }
            return finish(outcome)
        }
    }

    private func finish(_ outcome: Outcome) -> ResolvedVAST {
        switch outcome {
        case let .resolved(ads):
            ResolvedVAST(chain: chain, ads: ads, adFailures: adFailures, issues: issues)
        case let .failed(failure):
            ResolvedVAST(chain: chain, failure: failure.code, failureErrorURLs: failure.errorURLs, adFailures: adFailures, issues: issues)
        }
    }

    // MARK: Documents

    /// The ads a document contributes, by pod / buffet rules and the requesting wrapper's policy.
    private mutating func resolveDocument(_ document: VASTDocument, hop: Int, trail: Trail, policy: Policy) async -> Outcome {
        var entries = document.ads.enumerated().map { Entry(index: $0.offset, ad: $0.element) }
        if !policy.followsWrappers {
            for entry in entries where entry.ad.body.isWrapper {
                report(.warning, "vast.wrapper.notFollowed",
                       "The requesting wrapper has followAdditionalWrappers=\"false\", so this wrapper is ignored.",
                       Self.path(hop: hop, "VAST/Ad[\(entry.index + 1)]/Wrapper"))
            }
            entries.removeAll { $0.ad.body.isWrapper }
        }
        guard !entries.isEmpty else {
            chain[hop].error = .noAdsAfterWrapper
            if hop > 0 {
                report(.error, "vast.wrapper.noAd", "The wrapper's response has no usable ad (VAST error 303).", Self.path(hop: hop, "VAST"))
            }
            let rootErrors = document.ads.isEmpty ? document.errors : []
            return .failed(failure(.noAdsAfterWrapper, trail: trail, rootErrors: rootErrors, at: Self.path(hop: hop, "VAST")))
        }

        let pod = entries.filter { $0.ad.sequence != nil }
            .sorted { ($0.ad.sequence ?? 0, $0.index) < ($1.ad.sequence ?? 0, $1.index) }
        let buffet = entries.filter { $0.ad.sequence == nil }

        if !policy.allowsMultipleAds {
            // `entries` is not empty, so one of the two exists.
            guard let chosen = buffet.first ?? pod.first else {
                return .failed(failure(.noAdsAfterWrapper, trail: trail, at: Self.path(hop: hop, "VAST")))
            }
            if buffet.isEmpty {
                // VAST 3.0–4.2 allow only "the first stand-alone Ad" here and do not say what a player does with a pod. The
                // simulator plays the pod's first ad (a lone `sequence="1"` ad is common) and warns: stricter players reject it.
                report(.warning, "vast.wrapper.allowMultipleAds",
                       "The requesting wrapper does not allow multiple ads (allowMultipleAds=\"false\"), so only a stand-alone ad (no sequence) is allowed, but the response is a pod. The simulator plays the pod's first ad; stricter players treat the response as having no ad (VAST error 303).",
                       Self.path(hop: hop, "VAST/Ad[\(chosen.index + 1)]"))
            } else if entries.count > 1 {
                report(.info, "vast.wrapper.allowMultipleAds",
                       "The requesting wrapper does not allow multiple ads (allowMultipleAds=\"false\"): only the first stand-alone ad is used.",
                       Self.path(hop: hop, "VAST/Ad[\(chosen.index + 1)]"))
            }
            return await resolveAd(chosen, hop: hop, trail: trail)
        }

        var resolved: [ResolvedVASTAd] = []
        var failures: [Failure] = []
        var spareBuffet = buffet[...]
        for slot in pod {
            switch await resolveAd(slot, hop: hop, trail: trail) {
            case let .resolved(ads):
                resolved += ads
            case let .failed(failure):
                failures.append(failure)
                guard failure.fallbackOnNoAd else { continue }
                if let replacement = await firstResolving(&spareBuffet, hop: hop, trail: trail, failures: &failures) {
                    report(.info, "vast.pod.fallbackOnNoAd",
                           "Pod ad sequence=\(slot.ad.sequence ?? 0) returned no ad; a buffet ad replaces it (fallbackOnNoAd=\"true\").",
                           Self.path(hop: hop, "VAST/Ad[\(slot.index + 1)]"))
                    resolved += replacement
                }
            }
        }
        if resolved.isEmpty, let replacement = await firstResolving(&spareBuffet, hop: hop, trail: trail, failures: &failures) {
            if !pod.isEmpty {
                report(.info, "vast.pod.buffetUsed", "No pod ad could be played; the first playable buffet ad is used instead.",
                       Self.path(hop: hop, "VAST"))
            }
            resolved = replacement
        }

        guard resolved.isEmpty, let first = failures.first else {
            record(failures)
            return .resolved(resolved)
        }
        record(failures.dropFirst())
        return .failed(first)
    }

    /// Resolves buffet ads in order until one plays; failed attempts are appended to `failures`.
    private mutating func firstResolving(_ buffet: inout ArraySlice<Entry>, hop: Int, trail: Trail,
                                         failures: inout [Failure]) async -> [ResolvedVASTAd]? {
        while let entry = buffet.popFirst() {
            switch await resolveAd(entry, hop: hop, trail: trail) {
            case let .resolved(ads): return ads
            case let .failed(failure): failures.append(failure)
            }
        }
        return nil
    }

    /// Budget stops are not failures of the ad: they are dropped without Error URLs.
    private mutating func record<Failures: Sequence<Failure>>(_ failures: Failures) {
        adFailures += failures.filter { !$0.isBudgetStop }.map { VASTAdFailure(code: $0.code, errorURLs: $0.errorURLs, origin: $0.origin) }
    }

    // MARK: Tracker budget

    /// Takes `count` merged entries from the budget; the first refusal reports the issue and stops the resolution.
    private mutating func charge(_ count: Int, at path: String) -> Bool {
        guard !budgetExhausted else { return false }
        let total = VASTTrackerLayer.saturatingSum(mergedTrackerCount, count)
        guard total <= resolver.maxMergedTrackers else {
            budgetExhausted = true
            report(.error, "vast.trackers.budget",
                   "Merging this ad's wrapper trackers would take the response past \(resolver.maxMergedTrackers) merged tracker entries, the simulator's limit: resolution stops here. The ads resolved so far play; the rest are dropped without fetching or firing their Error URLs.",
                   path)
            return false
        }
        mergedTrackerCount = total
        return true
    }

    /// A failure with the Error URLs of every document on the way (outermost first, then `rootErrors`), charged to the
    /// budget; a budget stop when they do not fit.
    private mutating func failure(_ code: VASTErrorCode, trail: Trail, rootErrors: [String] = [], at path: String) -> Failure {
        guard charge(VASTTrackerLayer.saturatingSum(trail.errorCount, rootErrors.count), at: path) else {
            return .budgetStop(origin: trail.origin)
        }
        return Failure(code: code, errorURLs: trail.errors + rootErrors, origin: trail.origin)
    }

    // MARK: Ads

    private mutating func resolveAd(_ entry: Entry, hop: Int, trail: Trail) async -> Outcome {
        let origin = VASTAdOrigin(hop: hop, ad: entry.index)
        guard !budgetExhausted else { return .failed(.budgetStop(origin: trail.origin + [origin])) }
        let trail = trail.appending(entry.ad, at: origin)
        switch entry.ad.body {
        case let .inline(inline):
            let inlinePath = Self.path(hop: hop, "VAST/Ad[\(entry.index + 1)]/InLine")
            if let block = trail.layer?.block(of: inline.categories) {
                let category = inline.categories[block.index]
                let authority = category.authority.map { " (authority \($0))" } ?? ""
                report(.error, "vast.category.blocked",
                       "Category \(category.code)\(authority) is blocked by the BlockedAdCategories of the wrapper at "
                           + Self.path(hop: block.wrapper.hop, "VAST/Ad[\(block.wrapper.ad + 1)]")
                           + ": the ad is not used (VAST error \(VASTErrorCode.blockedAdCategory.rawValue), InLine Category violates Wrapper BlockedAdCategories).",
                       inlinePath + "/Category[\(block.index + 1)]")
                return .failed(failure(.blockedAdCategory, trail: trail, at: inlinePath))
            }
            if inline.categories.isEmpty, trail.layer?.blocksCategories == true {
                report(.warning, "vast.category.unverifiable",
                       "A wrapper above blocks ad categories (BlockedAdCategories), but this InLine ad declares no <Category>: the simulator plays it; players that require categories reject it with VAST error \(VASTErrorCode.adCategoryRequired.rawValue) (ad category required but not provided).",
                       inlinePath)
            }
            guard charge(trail.trackerCount, at: Self.path(hop: hop, "VAST/Ad[\(entry.index + 1)]")) else {
                return .failed(.budgetStop(origin: trail.origin))
            }
            return .resolved([trail.resolvedAd(inline)])
        case let .wrapper(wrapper):
            let outcome = await follow(wrapper, at: origin, trail: trail)
            guard case var .failed(failure) = outcome else { return outcome }
            // `fallbackOnNoAd` is the instruction of the wrapper directly in this document, for "no ad" only.
            failure.fallbackOnNoAd = wrapper.fallbackOnNoAd && failure.code == .noAdsAfterWrapper
            return .failed(failure)
        }
    }

    /// Fetches and resolves the wrapper's response. `trail` already includes the wrapper.
    private mutating func follow(_ wrapper: VASTWrapper, at origin: VASTAdOrigin, trail: Trail) async -> Outcome {
        let wrapperPath = Self.path(hop: origin.hop, "VAST/Ad[\(origin.ad + 1)]/Wrapper")
        func failed(_ code: VASTErrorCode) -> Outcome {
            .failed(failure(code, trail: trail, at: wrapperPath))
        }

        guard !wrapper.adTagURI.isEmpty else { return failed(.wrapperError) }
        guard trail.wrapperCount < resolver.maxDepth else {
            report(.error, "vast.wrapper.depth",
                   "More than \(max(resolver.maxDepth, 0)) wrappers in a row: the wrapper limit is reached and this one is not followed (VAST error 302).",
                   wrapperPath)
            return failed(.wrapperLimit)
        }
        guard fetchCount < resolver.maxFetches else {
            report(.error, "vast.wrapper.fetchLimit",
                   "More than \(resolver.maxFetches) VAST fetches for one response: this wrapper is not followed (VAST error 302).", wrapperPath)
            return failed(.wrapperLimit)
        }
        let template = wrapper.adTagURI
        let url = expandedTagURI(template)
        guard VASTURLCheck.scheme(of: url) != nil, !url.contains(where: \.isWhitespace) else {
            report(.error, "vast.wrapper.adTagURI.invalid", "The VASTAdTagURI is not an absolute URL, so it cannot be fetched (VAST error 300).",
                   wrapperPath + "/VASTAdTagURI")
            return failed(.wrapperError)
        }

        fetchCount += 1
        let hop = chain.count
        let body: String
        do {
            let response = try await resolver.fetcher.fetchVAST(url, template: template, parentRequestID: requestID(ofHop: origin.hop))
            chain.append(VASTHop(url: url, requestID: response.requestID, parent: origin, template: template))
            body = response.body
        } catch {
            chain.append(VASTHop(url: url, error: .wrapperTimeout, parent: origin, template: template))
            report(.error, "vast.wrapper.fetch.failed", "The VASTAdTagURI could not be loaded: \(Self.describe(error)) (VAST error 301).",
                   wrapperPath + "/VASTAdTagURI")
            return failed(.wrapperTimeout)
        }

        switch parse(body, hop: hop, served: true) {
        case let .failed(code):
            chain[hop].error = code
            return failed(code)
        case let .document(document):
            chain[hop].document = document
            var inner = trail
            inner.wrapperCount += 1
            let policy = Policy(allowsMultipleAds: wrapper.allowMultipleAds, followsWrappers: wrapper.followAdditionalWrappers)
            return await resolveDocument(document, hop: hop, trail: inner, policy: policy)
        }
    }

    // MARK: Wrapper companions

    /// Wrapper companion tracking that matches no InLine companion (`VASTCompanionMatch`) is never fired: report each
    /// wrapper layer and InLine companion it concerns, once.
    private mutating func reportUnmatchedWrapperCompanions(_ ads: [ResolvedVASTAd]) {
        var reported = Set<String>()
        for ad in ads {
            let companions = ad.inline.creatives.flatMap(\.companions)
            guard !companions.isEmpty, let lineage = VASTLineage(origin: ad.origin, chain: chain) else { continue }
            for layer in lineage.layers.dropLast() {
                let candidates = layer.wrapperCompanions
                guard !candidates.isEmpty else { continue }
                for (index, companion) in companions.enumerated()
                    where VASTCompanionMatch.wrapperCompanionIndices(for: companion, in: candidates).isEmpty {
                    let path = Self.path(hop: layer.origin.hop, "VAST/Ad[" + VASTLabel.ordinal(layer.origin.ad) + "]/Wrapper/Creatives")
                    let message = "None of the wrapper's \(candidates.count) tracking companions matches the id or size of the InLine "
                        + VASTLabel.companion(companion, index: index, withSize: true)
                        + ", so their creativeView and CompanionClickTracking are not fired when it is shown or clicked."
                    if reported.insert(path + message).inserted {
                        report(.warning, "vast.wrapper.companion.unmatched", message, path)
                    }
                }
            }
        }
    }

    // MARK: Parsing

    /// `served`: a request delivered the body (anything but the bid's own `adm`).
    private mutating func parse(_ body: String, hop: Int, served: Bool) -> ParsedBody {
        guard body.contains(where: { !$0.isWhitespace }) else {
            report(.error, "vast.response.empty", hop == 0 ? "The VAST response is empty (VAST error 303)." : "The wrapper's response is empty (VAST error 303).",
                   Self.path(hop: hop, "VAST"))
            return .failed(.noAdsAfterWrapper)
        }
        switch VASTParser.outcome(of: body, requireSecure: resolver.requireSecure) {
        case let .document(document, documentIssues, macroSites):
            issues += documentIssues.map { Self.prefixed($0, hop: hop) }
            if served { reportUnsubstitutedMacros(macroSites, hop: hop) }
            return .document(document)
        case let .notXML(documentIssues):
            issues += documentIssues.map { Self.prefixed($0, hop: hop) }
            return .failed(.xmlParsing)
        case let .notVAST(documentIssues):
            issues += documentIssues.map { Self.prefixed($0, hop: hop) }
            return .failed(.schemaValidation)
        }
    }

    /// One warning per served document that still carries OpenRTB `${…}`, at its first such element.
    private mutating func reportUnsubstitutedMacros(_ sites: [VASTMacroSite], hop: Int) {
        guard let first = sites.first else { return }
        var macros = OrderedTokens()
        for site in sites {
            for macro in site.macros { macros.insert(macro) }
        }
        let shownLimit = 5
        let shown = macros.values.prefix(shownLimit).joined(separator: ", ") + (macros.values.count > shownLimit ? ", …" : "")
        let document = hop == 0 ? "a fetched VAST document (delivered by the win notice, AdCOM curl or a VAST tag URL)" : "a wrapper-served document"
        let elements = sites.count == 1 ? "1 element" : "\(sites.count) elements"
        report(.warning, "vast.macro.openrtb.unsubstituted",
               "Unsubstituted OpenRTB macro in \(document): \(shown) stays literal in \(elements) when fired. Only the exchange substitutes ${…}, and only in the bid's own adm (OpenRTB 2.6 §4.4); a VAST player expands […] macros only (VAST 4.1 §6.1).",
               Self.path(hop: hop, first.path))
    }

    private func requestID(ofHop hop: Int) -> UUID? {
        chain.indices.contains(hop) ? chain[hop].requestID : nil
    }

    /// The URL to request for a request URI: VAST `[…]` macros expanded in http(s) URIs when there is a context.
    private func expandedTagURI(_ uri: String) -> String {
        guard let context = resolver.macroContext, let scheme = VASTURLCheck.scheme(of: uri), scheme == "http" || scheme == "https" else {
            return uri
        }
        return MacroExpander.expandVAST(uri, context: context).url
    }

    // MARK: Issues

    private mutating func report(_ severity: ValidationIssue.Severity, _ code: String, _ message: String, _ path: String) {
        issues.append(ValidationIssue(severity, code: code, message: message, path: path))
    }

    /// Paths inside fetched documents name the hop: `hop 2 › VAST/Ad[1]/InLine/Impression`.
    static func path(hop: Int, _ path: String) -> String {
        hop == 0 ? path : "hop \(hop) › " + path
    }

    private static func prefixed(_ issue: ValidationIssue, hop: Int) -> ValidationIssue {
        var issue = issue
        issue.path = path(hop: hop, issue.path)
        return issue
    }

    private static func describe(_ error: any Error) -> String {
        let text = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        return String(text.prefix(300))
    }
}

// MARK: - Values

/// The requesting wrapper's instructions for its response (the player itself allows pods and wrappers).
private struct Policy {
    var allowsMultipleAds: Bool
    var followsWrappers: Bool

    static let player = Policy(allowsMultipleAds: true, followsWrappers: true)
}

private struct Entry {
    var index: Int
    var ad: VASTAd
}

private struct Failure {
    var code: VASTErrorCode
    /// Outermost first.
    var errorURLs: [String] = []
    var origin: [VASTAdOrigin] = []
    var fallbackOnNoAd = false
    /// The tracker budget stopped the resolution here: no Error URLs, never recorded as an ad failure.
    var isBudgetStop = false

    /// 302: a limit "defined by the media player" (VAST 4.1 §2.3.6.3), like the wrapper and fetch limits.
    static func budgetStop(origin: [VASTAdOrigin]) -> Failure {
        Failure(code: .wrapperLimit, origin: origin, isBudgetStop: true)
    }
}

private enum Outcome {
    /// One or more playable ads (a wrapper with `allowMultipleAds` can expand into a pod).
    case resolved([ResolvedVASTAd])
    case failed(Failure)
}

private enum ParsedBody {
    case document(VASTDocument)
    case failed(VASTErrorCode)
}

/// What the documents above an ad contribute, outermost first. The trackers live in a shared layer chain: appending an
/// ad adds one layer for that ad's own trackers and copies nothing above it.
private struct Trail {
    var origin: [VASTAdOrigin] = []
    var layer: VASTTrackerLayer?
    /// Wrappers followed so far in this chain.
    var wrapperCount = 0
    /// The outermost `sequence` on the way down: the pod slot this ad plays in.
    var slotSequence: Int?

    func appending(_ ad: VASTAd, at origin: VASTAdOrigin) -> Trail {
        var trail = self
        trail.origin.append(origin)
        trail.layer = VASTTrackerLayer(parent: layer, body: ad.body, origin: origin)
        trail.slotSequence = slotSequence ?? ad.sequence
        return trail
    }

    /// Merged budget entries of the trail.
    var trackerCount: Int { layer?.cumulativeCount ?? 0 }
    var errorCount: Int { layer?.cumulativeErrorCount ?? 0 }
    /// Every Error URL of the trail, outermost first (materialised: charge `errorCount` first).
    var errors: [String] { layer?.collect(\.errors) ?? [] }

    /// The inline ad with every tracker of the trail (which already includes the inline ad itself).
    func resolvedAd(_ inline: VASTInline) -> ResolvedVASTAd {
        ResolvedVASTAd(inline: inline, sequence: slotSequence, origin: origin, layer: layer)
    }
}
