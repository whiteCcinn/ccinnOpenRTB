import Foundation

/// OpenRTB 3.0 / AdCOM 1.0 display trackers: `display.event[]` and the image banner's `link`.
enum AdcomTracking {
    /// AdCOM 1.0 "Event Types": 1 loaded (markup delivered, before rendering), 2 impression.
    static let loadedEvent = 1
    static let impressionEvent = 2

    /// AdCOM 1.0 viewability event types: 3 viewable-mrc50, 4 viewable-mrc100, 5 viewable-video50.
    static func eventType(for level: ViewabilityLevel) -> Int {
        switch level {
        case .mrc50: 3
        case .mrc100: 4
        case .video50: 5
        }
    }

    /// `.rendered`: every type-1 (loaded) event, then every type-2 (impression) event, each group in document order.
    static func rendered(_ events: [AdcomEvent], factory: TrackerRequestFactory) -> [TrackerRequest] {
        requests(events, type: loadedEvent, category: .event, trigger: "loaded (AdCOM 1)", factory: factory)
            + requests(events, type: impressionEvent, category: .impression, trigger: "impression (AdCOM 2)", factory: factory)
    }

    /// `.viewable(level)`: the events of type 3 / 4 / 5.
    static func viewable(_ events: [AdcomEvent], level: ViewabilityLevel, factory: TrackerRequestFactory) -> [TrackerRequest] {
        let type = eventType(for: level)
        return requests(events, type: type, category: .viewability, trigger: ViewabilityLabels.trigger(level) + " (AdCOM \(type))", factory: factory)
    }

    /// `.click` on an image banner: `link.trkr[]`, then one navigation to `link.url` (noting `urlfb`).
    static func click(_ link: AdLink, factory: TrackerRequestFactory) -> [TrackerRequest] {
        let trackers = link.clickTrackers.enumerated().map { index, url in
            (template: url, source: factory.source("display", "banner", "link", "trkr[\(index)]"))
        }
        return factory.click(trackers: trackers, destination: link.url, fallback: link.fallback,
                             destinationSource: factory.source("display", "banner", "link"))
    }

    /// Method 2 (JavaScript) loads `url` as a script, or injects the inline script; vendor methods (500+) are recorded
    /// as URLs.
    private static func requests(_ events: [AdcomEvent], type: Int, category: TrackerCategory, trigger: String,
                                 factory: TrackerRequestFactory) -> [TrackerRequest] {
        var requests: [TrackerRequest] = []
        for (index, event) in events.enumerated() where event.type == type {
            let source = factory.source("display", "event[\(index)]")
            if let url = event.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requests.append(factory.url(url, category: category, trigger: trigger, source: source, isScript: event.method == 2))
            } else if let script = event.script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requests.append(factory.script(script, category: category, trigger: trigger, source: source))
            }
        }
        return requests
    }
}
