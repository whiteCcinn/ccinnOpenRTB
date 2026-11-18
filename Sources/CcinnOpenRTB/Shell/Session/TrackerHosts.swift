import CcinnOpenRTBKit
import Foundation
import RTBKit

/// The tracker hosts of a bid, listed by the Real-mode confirmation (design D9): every host Real mode could send a
/// tracker to. Content (VAST wrappers, media, images) is fetched in both modes and is not listed.
enum TrackerHosts {
    struct Host: Hashable, Identifiable, Sendable {
        var name: String
        /// Kinds of trackers that go to this host ("win", "impression", …), in first-seen order.
        var kinds: [String]
        var count: Int
        var id: String { name }
    }

    struct Summary: Hashable, Sendable {
        var hosts: [Host]
        /// Trackers whose host is not known yet (e.g. a VAST tag that is resolved when the ad renders).
        var notes: [String]
        var trackerCount: Int { hosts.reduce(0) { $0 + $1.count } }
    }

    /// One tracker URL template with its kind.
    struct Template: Hashable, Sendable {
        var kind: String
        var url: String
    }

    /// The note for requests no list can know in advance: what scripts and creatives load at run time.
    static let scriptsNote = "Plus requests the creative's own scripts may make: script trackers and HTML creatives load what their code decides at run time, which cannot be listed in advance."

    static func summary(candidate: AdCandidate?, native: NativeAd?, vastDocuments: [VASTDocument], resolved: ResolvedVAST?,
                        nativeVideo: ResolvedVAST? = nil) -> Summary {
        guard let candidate else { return Summary(hosts: [], notes: ["No bid is selected."]) }
        var templates = auctionTemplates(candidate)
        var notes: [String] = []
        if let native {
            templates += nativeTemplates(native)
            // The video asset's VAST: its resolution, else the inline document, else a note.
            if let nativeVideo {
                templates += resolvedTemplates(nativeVideo)
            } else if let source = native.assets.lazy.compactMap(\.vastSource).first {
                switch source {
                case let .xml(xml):
                    if let document = VASTParser.parse(xml).document {
                        templates += documentTemplates(document)
                        if hasWrapper(document) {
                            notes.append("Trackers in the Native video's VAST wrappers are fetched when the video plays and are not listed yet.")
                        }
                    }
                case let .url(url):
                    notes.append("The Native video's VAST tag at \(URLText.host(url) ?? url) is being fetched; its trackers are listed once it is resolved.")
                }
            }
        }
        if let resolved {
            templates += resolvedTemplates(resolved)
        } else {
            for document in vastDocuments { templates += documentTemplates(document) }
        }
        switch candidate.markup {
        case let .vast(.url(url)) where resolved == nil:
            notes.append("The VAST tag at \(URLText.host(url) ?? url) is fetched when the ad renders; its trackers are not listed yet.")
        case .vast where resolved == nil && vastDocuments.contains(where: Self.hasWrapper):
            notes.append("Trackers in VAST wrappers further down the chain are fetched when the ad renders and are not listed yet.")
        case .native where native == nil:
            notes.append("The Native markup could not be read; its trackers are not listed.")
        case .none:
            notes.append(candidate.markupURL != nil
                ? "The markup is fetched from display.curl when the ad renders; trackers inside it are not listed yet."
                : "The markup is delivered by the win notice; trackers inside it are not listed yet.")
        default:
            break
        }
        if case .html = candidate.markup {
            notes.append("Trackers inside the HTML creative are loaded by the creative itself (blocked in Simulated mode unless allowed).")
        }
        let hasScripts = templates.contains { $0.kind == "script" } || native?.jsTracker != nil
            || candidate.adcomEvents.contains { $0.method == 2 }
        if hasScripts || isHTML(candidate.markup) { notes.append(scriptsNote) }
        return Summary(hosts: hosts(of: templates), notes: notes)
    }

    private static func isHTML(_ markup: AdMarkup) -> Bool {
        if case .html = markup { true } else { false }
    }

    /// Groups templates by host; hosts sorted by name. Templates without a host (relative, `data:`) are skipped.
    static func hosts(of templates: [Template]) -> [Host] {
        var byName: [String: Host] = [:]
        for template in templates {
            guard let name = host(of: template.url) else { continue }
            var host = byName[name] ?? Host(name: name, kinds: [], count: 0)
            if !host.kinds.contains(template.kind) { host.kinds.append(template.kind) }
            host.count += 1
            byName[name] = host
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// The host of an http(s) or protocol-relative tracker template (macros allowed); `nil` for anything else.
    static func host(of template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        guard let scheme = URLText.scheme(absolute), scheme == "http" || scheme == "https" else { return nil }
        guard let host = URLText.host(absolute), !host.isEmpty else { return nil }
        return host
    }

    static func auctionTemplates(_ candidate: AdCandidate) -> [Template] {
        var result: [Template] = []
        if let url = candidate.winURL { result.append(Template(kind: "win", url: url)) }
        if let url = candidate.billingURL { result.append(Template(kind: "billing", url: url)) }
        if let url = candidate.lossURL { result.append(Template(kind: "loss", url: url)) }
        for event in candidate.adcomEvents {
            if let url = event.url { result.append(Template(kind: event.method == 2 ? "script" : adcomKind(event.type), url: url)) }
            if let script = event.script { result += scriptSources(script).map { Template(kind: "script", url: $0) } }
        }
        return result
    }

    static func nativeTemplates(_ native: NativeAd) -> [Template] {
        var result = native.impressionTrackers.map { Template(kind: "impression", url: $0) }
        for tracker in native.eventTrackers {
            result.append(Template(kind: tracker.method == 2 ? "script" : nativeKind(tracker.event), url: tracker.url))
        }
        result += native.link.clickTrackers.map { Template(kind: "click", url: $0) }
        for asset in native.assets {
            result += (asset.link?.clickTrackers ?? []).map { Template(kind: "click", url: $0) }
        }
        if let script = native.jsTracker { result += scriptSources(script).map { Template(kind: "script", url: $0) } }
        return result
    }

    static func resolvedTemplates(_ vast: ResolvedVAST) -> [Template] {
        var result: [Template] = []
        for ad in vast.ads {
            result += ad.impressions.map { Template(kind: "impression", url: $0) }
            result += ad.trackingEvents.map { Template(kind: "event", url: $0.url) }
            result += ad.clickTrackings.map { Template(kind: "click", url: $0) }
            result += ad.errors.map { Template(kind: "error", url: $0) }
            result += viewableTemplates(ad.viewableImpression)
            for verification in ad.verifications { result += verification.trackingEvents.map { Template(kind: "verification", url: $0.url) } }
            for companion in ad.inline.creatives.flatMap(\.companions) { result += companionTemplates(companion) }
        }
        result += vast.failureErrorURLs.map { Template(kind: "error", url: $0) }
        for failure in vast.adFailures { result += failure.errorURLs.map { Template(kind: "error", url: $0) } }
        return result
    }

    /// Trackers written in one VAST document (before resolution: wrappers and inline ads alike).
    static func documentTemplates(_ document: VASTDocument) -> [Template] {
        var result = document.errors.map { Template(kind: "error", url: $0) }
        for ad in document.ads {
            let impressions: [String], errors: [String], creatives: [VASTCreative], viewable: VASTViewableImpression?, verifications: [VASTVerification]
            switch ad.body {
            case let .inline(inline):
                (impressions, errors, creatives, viewable, verifications) = (inline.impressions, inline.errors, inline.creatives,
                                                                             inline.viewableImpression, inline.verifications)
            case let .wrapper(wrapper):
                (impressions, errors, creatives, viewable, verifications) = (wrapper.impressions, wrapper.errors, wrapper.creatives,
                                                                             wrapper.viewableImpression, wrapper.verifications)
            }
            result += impressions.map { Template(kind: "impression", url: $0) }
            result += errors.map { Template(kind: "error", url: $0) }
            for creative in creatives {
                if let linear = creative.linear {
                    result += linear.trackingEvents.map { Template(kind: "event", url: $0.url) }
                    result += linear.clickTrackings.map { Template(kind: "click", url: $0) }
                }
                for companion in creative.companions { result += companionTemplates(companion) }
            }
            if let viewable { result += viewableTemplates(viewable) }
            for verification in verifications { result += verification.trackingEvents.map { Template(kind: "verification", url: $0.url) } }
        }
        return result
    }

    private static func companionTemplates(_ companion: VASTCompanion) -> [Template] {
        companion.trackingEvents.map { Template(kind: "event", url: $0.url) } + companion.clickTrackings.map { Template(kind: "click", url: $0) }
    }

    private static func viewableTemplates(_ viewable: VASTViewableImpression) -> [Template] {
        (viewable.viewable + viewable.notViewable + viewable.viewUndetermined).map { Template(kind: "viewability", url: $0) }
    }

    private static func hasWrapper(_ document: VASTDocument) -> Bool {
        document.ads.contains { if case .wrapper = $0.body { true } else { false } }
    }

    /// AdCOM 1.0 event types: 1 loaded and 2 impression (both fire with `.rendered`), 3–5 viewable, 500+ vendor-specific.
    private static func adcomKind(_ type: Int) -> String {
        switch type {
        case 1, 2: "impression"
        case 3, 4, 5: "viewability"
        default: "event"
        }
    }

    /// Native 1.2 event types: 1 impression, 2–4 viewable, 500+ exchange-specific.
    private static func nativeKind(_ type: Int) -> String {
        switch type {
        case 1: "impression"
        case 2, 3, 4: "viewability"
        default: "event"
        }
    }

    /// The resource URLs of tracker markup (Native `jstracker`, AdCOM JavaScript events), read as HTML: `src` / `href` /
    /// `data` / `poster` of resource elements, with quoted, unquoted and character-reference-encoded values; a bare URL
    /// counts as its own source. What scripts load at run time is not here (see `scriptsNote`).
    static func scriptSources(_ markup: String) -> [String] {
        let trimmed = markup.trimmingCharacters(in: .whitespacesAndNewlines)
        if host(of: trimmed) != nil, !trimmed.contains("<") { return [trimmed] }
        return HTMLResourceScanner.resourceURLs(in: trimmed)
    }
}
