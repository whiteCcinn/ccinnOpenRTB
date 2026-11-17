import Foundation

/// Builds `TrackerRequest`s for exchange-side trackers (OpenRTB notices, AdCOM events, Native trackers and clicks):
/// only OpenRTB `${…}` macros are substituted there, as an exchange would (`MacroExpander.expandOpenRTB`).
struct TrackerRequestFactory {
    let context: MacroContext
    /// `bid <seat>.<bid>`.
    let root: String

    init(candidate: AdCandidate, context: MacroContext) {
        self.context = context
        root = "bid " + candidate.id
    }

    func source(_ components: String...) -> String {
        ([root] + components).joined(separator: " › ")
    }

    /// A URL tracker (`isScript`: a JavaScript URL injected as `<script src>`).
    func url(_ template: String, category: TrackerCategory, trigger: String, source: String, isScript: Bool = false,
             parentID: UUID? = nil) -> TrackerRequest {
        let expanded = MacroExpander.expandOpenRTB(template, context: context)
        return TrackerRequest(parentID: parentID, category: category, trigger: trigger, source: source, template: template, url: expanded.url,
                              replacedMacros: expanded.replaced, unknownMacros: expanded.unknown, isScript: isScript)
    }

    /// A script tracker given as HTML/JavaScript markup (Native `jstracker`): `template` and `url` hold the markup, which the
    /// renderer injects as is (Real mode only).
    func script(_ markup: String, category: TrackerCategory, trigger: String, source: String) -> TrackerRequest {
        let expanded = MacroExpander.expandMarkup(markup, context: context)
        return TrackerRequest(category: category, trigger: trigger, source: source, template: markup, url: expanded.url,
                              replacedMacros: expanded.replaced, unknownMacros: expanded.unknown, isScript: true)
    }

    /// Click trackers, then one navigation to `url` (its parent is the first click tracker). No navigation on devices
    /// without click-through (CTV) or when `url` is blank.
    func click(trackers: [(template: String, source: String)], destination: String?, fallback: String?, destinationSource: String)
        -> [TrackerRequest] {
        var requests = trackers.map { url($0.template, category: .click, trigger: "click", source: $0.source) }
        guard context.device?.supportsClickThrough ?? true,
              let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return requests }
        var trigger = "click-through"
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { trigger += " (fallback: \(fallback))" }
        requests.append(url(destination, category: .navigation, trigger: trigger, source: destinationSource, parentID: requests.first?.id))
        return requests
    }
}
