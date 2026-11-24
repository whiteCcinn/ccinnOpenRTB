import Foundation

/// Builds `TrackerRequest`s for the URLs of one document: the bid response itself (OpenRTB notices, AdCOM events and the
/// AdCOM banner link) or the markup (Native trackers, clicktrackers and link).
///
/// What is substituted depends on that document (decisions.md "Macros"):
/// - `.bidResponse`: OpenRTB `${…}` only, as the exchange does (`MacroExpander.expandOpenRTB`; OpenRTB 2.6 §4.4);
/// - `.markup`: nothing. The SDK fires Native URLs as written: an inline `adm` was substituted by the exchange before it
///   was parsed, and markup a request delivered never was. Every `${…}` / `[…]` left is reported in `unknownMacros`.
///
/// Every request gets `parentID`, the request that delivered the document (`nil` for the pasted bid response and for
/// markup carried inline in it).
struct TrackerRequestFactory {
    enum Origin {
        case bidResponse, markup
    }

    let context: MacroContext
    let parentID: UUID?
    let origin: Origin
    /// `bid <seat>.<bid>`.
    let root: String

    init(candidate: AdCandidate, context: MacroContext, origin: Origin, parentID: UUID? = nil) {
        self.context = context
        self.parentID = parentID
        self.origin = origin
        root = "bid " + candidate.id
    }

    func source(_ components: String...) -> String {
        ([root] + components).joined(separator: " › ")
    }

    /// A URL tracker (`isScript`: a JavaScript URL injected as `<script src>`).
    func url(_ template: String, category: TrackerCategory, trigger: String, source: String, isScript: Bool = false) -> TrackerRequest {
        let expanded = switch origin {
        case .bidResponse: MacroExpander.expandOpenRTB(template, context: context)
        case .markup: MacroExpander.literal(template)
        }
        return TrackerRequest(parentID: parentID, category: category, trigger: trigger, source: source, template: template, url: expanded.url,
                              replacedMacros: expanded.replaced, unknownMacros: expanded.unknown, isScript: isScript)
    }

    /// A script tracker given as HTML/JavaScript markup (Native `jstracker`, AdCOM inline script): `template` and `url` hold
    /// the markup, which the renderer injects as is (Real mode only).
    func script(_ markup: String, category: TrackerCategory, trigger: String, source: String) -> TrackerRequest {
        let expanded = switch origin {
        case .bidResponse: MacroExpander.expandMarkup(markup, context: context)
        case .markup: MacroExpander.literalMarkup(markup)
        }
        return TrackerRequest(parentID: parentID, category: category, trigger: trigger, source: source, template: markup, url: expanded.url,
                              replacedMacros: expanded.replaced, unknownMacros: expanded.unknown, isScript: true)
    }

    /// One click: its click trackers, then one navigation to `destination`, all siblings with the trigger "click" (the
    /// click causes each of them; no tracker causes the navigation). A deep-link `fallback` travels with the navigation
    /// (macros expanded as its URL) and is noted in its source. No navigation on devices without click-through (CTV) or when `destination` is blank.
    func click(trackers: [(template: String, source: String)], destination: String?, fallback: String?, destinationSource: String)
        -> [TrackerRequest] {
        var requests = trackers.map { url($0.template, category: .click, trigger: Self.clickTrigger, source: $0.source) }
        guard context.device?.supportsClickThrough ?? true,
              let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return requests }
        var source = destinationSource
        var navigation: TrackerRequest
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source += " (fallback: \(fallback))"
            navigation = url(destination, category: .navigation, trigger: Self.clickTrigger, source: source)
            navigation.fallback = url(fallback, category: .navigation, trigger: Self.clickTrigger, source: source).url
        } else {
            navigation = url(destination, category: .navigation, trigger: Self.clickTrigger, source: source)
        }
        requests.append(navigation)
        return requests
    }

    static let clickTrigger = "click"
}
