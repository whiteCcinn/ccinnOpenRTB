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
/// - **Errors.** At most `maxDepth` wrappers are followed in a chain; the next one fails with 302 without being fetched.
///   A fetch that fails is 301. A response that is not XML is 100; XML that is not VAST is 101. An empty response, or
///   one with no usable ad, is 303, and a no-ad response's root `<Error>` URLs join the chain's. A wrapper without a
///   usable `VASTAdTagURI` is 300. Every Error URL of the failed chain (outermost first) is reported with the code.
/// - **Merging.** Trackers are merged outermost wrapper → inner wrappers → inline ad, per kind: Impression, Error, linear
///   Tracking, ClickTracking, ViewableImpression and AdVerifications.
/// - **Failures.** The first failure of an unplayable response is `failure`; every other failed attempt is an
///   `adFailures` entry, so each Error URL is reported exactly once.
/// - **Requests.** Fetches run one at a time in play order, so the chain and the network monitor are deterministic. Each
///   fetch is linked to the request that delivered the wrapper asking for it (`VASTHop.requestID`).
public struct VASTResolver: Sendable {
    public var fetcher: any VASTFetcher
    public var maxDepth: Int
    /// `imp.secure = 1`: non-HTTPS URLs are warnings instead of notes.
    public var requireSecure: Bool
    /// When set, VAST macros in http(s) tag URIs (`[CACHEBUSTING]`, `[TIMESTAMP]`, …) are expanded before fetching, as a
    /// player does. `data:` URIs are never expanded: their payload is a VAST document with its own macros.
    public var macroContext: MacroContext?
    /// Upper bound on fetches for one resolution (pods of wrappers fan out); further wrappers fail with 302.
    public var maxFetches: Int

    public init(fetcher: any VASTFetcher, maxDepth: Int = 5, requireSecure: Bool = false, macroContext: MacroContext? = nil,
                maxFetches: Int = 64) {
        self.fetcher = fetcher
        self.maxDepth = maxDepth
        self.requireSecure = requireSecure
        self.macroContext = macroContext
        self.maxFetches = maxFetches
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

    init(resolver: VASTResolver) {
        self.resolver = resolver
    }

    mutating func resolve(_ source: VASTSource, parentRequestID: UUID?) async -> ResolvedVAST {
        let parsed: ParsedBody
        switch source {
        case let .xml(xml):
            chain.append(VASTHop(requestID: parentRequestID))
            parsed = parse(xml, hop: 0)
        case let .url(rawURL):
            let url = expandedTagURI(rawURL.trimmingCharacters(in: .whitespacesAndNewlines))
            fetchCount += 1
            do {
                let response = try await resolver.fetcher.fetchVAST(url, parentRequestID: parentRequestID)
                chain.append(VASTHop(url: url, requestID: response.requestID))
                parsed = parse(response.body, hop: 0)
            } catch {
                chain.append(VASTHop(url: url, error: .wrapperTimeout))
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
            return .failed(Failure(code: .noAdsAfterWrapper, errorURLs: trail.errors + rootErrors, origin: trail.origin))
        }

        let pod = entries.filter { $0.ad.sequence != nil }
            .sorted { ($0.ad.sequence ?? 0, $0.index) < ($1.ad.sequence ?? 0, $1.index) }
        let buffet = entries.filter { $0.ad.sequence == nil }

        if !policy.allowsMultipleAds {
            // `entries` is not empty, so one of the two exists.
            guard let chosen = buffet.first ?? pod.first else {
                return .failed(Failure(code: .noAdsAfterWrapper, errorURLs: trail.errors, origin: trail.origin))
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

    private mutating func record<Failures: Sequence<Failure>>(_ failures: Failures) {
        adFailures += failures.map { VASTAdFailure(code: $0.code, errorURLs: $0.errorURLs, origin: $0.origin) }
    }

    // MARK: Ads

    private mutating func resolveAd(_ entry: Entry, hop: Int, trail: Trail) async -> Outcome {
        let origin = VASTAdOrigin(hop: hop, ad: entry.index)
        let trail = trail.appending(entry.ad, at: origin)
        switch entry.ad.body {
        case let .inline(inline):
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
            .failed(Failure(code: code, errorURLs: trail.errors, origin: trail.origin))
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
        let url = expandedTagURI(wrapper.adTagURI)
        guard VASTURLCheck.scheme(of: url) != nil, !url.contains(where: \.isWhitespace) else {
            report(.error, "vast.wrapper.adTagURI.invalid", "The VASTAdTagURI is not an absolute URL, so it cannot be fetched (VAST error 300).",
                   wrapperPath + "/VASTAdTagURI")
            return failed(.wrapperError)
        }

        fetchCount += 1
        let hop = chain.count
        let body: String
        do {
            let response = try await resolver.fetcher.fetchVAST(url, parentRequestID: requestID(ofHop: origin.hop))
            chain.append(VASTHop(url: url, requestID: response.requestID, parent: origin))
            body = response.body
        } catch {
            chain.append(VASTHop(url: url, error: .wrapperTimeout, parent: origin))
            report(.error, "vast.wrapper.fetch.failed", "The VASTAdTagURI could not be loaded: \(Self.describe(error)) (VAST error 301).",
                   wrapperPath + "/VASTAdTagURI")
            return failed(.wrapperTimeout)
        }

        switch parse(body, hop: hop) {
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

    // MARK: Parsing

    private mutating func parse(_ body: String, hop: Int) -> ParsedBody {
        guard body.contains(where: { !$0.isWhitespace }) else {
            report(.error, "vast.response.empty", hop == 0 ? "The VAST response is empty (VAST error 303)." : "The wrapper's response is empty (VAST error 303).",
                   Self.path(hop: hop, "VAST"))
            return .failed(.noAdsAfterWrapper)
        }
        switch VASTParser.outcome(of: body, requireSecure: resolver.requireSecure) {
        case let .document(document, documentIssues):
            issues += documentIssues.map { Self.prefixed($0, hop: hop) }
            return .document(document)
        case let .notXML(documentIssues):
            issues += documentIssues.map { Self.prefixed($0, hop: hop) }
            return .failed(.xmlParsing)
        case let .notVAST(documentIssues):
            issues += documentIssues.map { Self.prefixed($0, hop: hop) }
            return .failed(.schemaValidation)
        }
    }

    private func requestID(ofHop hop: Int) -> UUID? {
        chain.indices.contains(hop) ? chain[hop].requestID : nil
    }

    private func expandedTagURI(_ uri: String) -> String {
        guard let context = resolver.macroContext, let scheme = VASTURLCheck.scheme(of: uri), scheme == "http" || scheme == "https" else {
            return uri
        }
        return MacroExpander.expand(uri, context: context).url
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

/// What the wrappers above an ad contribute, outermost first.
private struct Trail {
    var origin: [VASTAdOrigin] = []
    var impressions: [String] = []
    var errors: [String] = []
    var trackingEvents: [VASTTracking] = []
    var clickTrackings: [String] = []
    var viewable = VASTViewableImpression()
    var verifications: [VASTVerification] = []
    /// Wrappers followed so far in this chain.
    var wrapperCount = 0
    /// The outermost `sequence` on the way down: the pod slot this ad plays in.
    var slotSequence: Int?

    func appending(_ ad: VASTAd, at origin: VASTAdOrigin) -> Trail {
        var trail = self
        trail.origin.append(origin)
        trail.impressions += ad.body.impressions
        trail.errors += ad.body.errors
        trail.trackingEvents += ad.body.linearTrackings
        trail.clickTrackings += ad.body.linearClickTrackings
        trail.viewable = viewable.merged(with: ad.body.viewableImpression)
        trail.verifications += ad.body.verifications
        trail.slotSequence = slotSequence ?? ad.sequence
        return trail
    }

    /// The inline ad with every tracker of the trail (which already includes the inline ad itself).
    func resolvedAd(_ inline: VASTInline) -> ResolvedVASTAd {
        ResolvedVASTAd(inline: inline, sequence: slotSequence, impressions: impressions, errors: errors, trackingEvents: trackingEvents,
                       clickTrackings: clickTrackings, viewableImpression: viewable, verifications: verifications, origin: origin)
    }
}
