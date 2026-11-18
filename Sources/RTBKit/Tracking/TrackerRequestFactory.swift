import Foundation

/// Builds `TrackerRequest`s for exchange-side trackers (OpenRTB notices, AdCOM events, Native trackers and clicks):
/// only OpenRTB `${…}` macros are substituted there, as an exchange would (`MacroExpander.expandOpenRTB`).
///
/// Every request it builds gets `parentID`: the request that delivered the markup (`TrackingPlan.Options.markupRequestID`).
struct TrackerRequestFactory {
    let context: MacroContext
    let parentID: UUID?
    /// `bid <seat>.<bid>`.
    let root: String

    init(candidate: AdCandidate, context: MacroContext, parentID: UUID? = nil) {
        self.context = context
        self.parentID = parentID
        root = "bid " + candidate.id
    }

    func source(_ components: String...) -> String {
        ([root] + components).joined(separator: " › ")
    }

    /// A URL tracker (`isScript`: a JavaScript URL injected as `<script src>`).
    func url(_ template: String, category: TrackerCategory, trigger: String, source: String, isScript: Bool = false) -> TrackerRequest {
        let expanded = MacroExpander.expandOpenRTB(template, context: context)
        return TrackerRequest(parentID: parentID, category: category, trigger: trigger, source: source, template: template, url: expanded.url,
                              replacedMacros: expanded.replaced, unknownMacros: expanded.unknown, isScript: isScript)
    }

    /// A script tracker given as HTML/JavaScript markup (Native `jstracker`, AdCOM inline script): `template` and `url` hold
    /// the markup, which the renderer injects as is (Real mode only).
    func script(_ markup: String, category: TrackerCategory, trigger: String, source: String) -> TrackerRequest {
        let expanded = MacroExpander.expandMarkup(markup, context: context)
        return TrackerRequest(parentID: parentID, category: category, trigger: trigger, source: source, template: markup, url: expanded.url,
                              replacedMacros: expanded.replaced, unknownMacros: expanded.unknown, isScript: true)
    }

    /// One click: its click trackers, then one navigation to `destination`, all siblings with the trigger "click" (the
    /// click causes each of them; no tracker causes the navigation). A deep-link `fallback` is noted in the navigation's
    /// source. No navigation on devices without click-through (CTV) or when `destination` is blank.
    func click(trackers: [(template: String, source: String)], destination: String?, fallback: String?, destinationSource: String)
        -> [TrackerRequest] {
        var requests = trackers.map { url($0.template, category: .click, trigger: Self.clickTrigger, source: $0.source) }
        guard context.device?.supportsClickThrough ?? true,
              let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return requests }
        var source = destinationSource
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { source += " (fallback: \(fallback))" }
        requests.append(url(destination, category: .navigation, trigger: Self.clickTrigger, source: source))
        return requests
    }

    static let clickTrigger = "click"
}
