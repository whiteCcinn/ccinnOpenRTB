import Foundation

/// Native 1.0–1.2 trackers per lifecycle event (design D7).
enum NativeTracking {
    /// Native 1.2 event types.
    static let impressionEvent = 1

    static func eventType(for level: ViewabilityLevel) -> Int {
        switch level {
        case .mrc50: 2
        case .mrc100: 3
        case .video50: 4
        }
    }

    /// `.rendered`: `imptrackers`, then `eventtrackers` with event 1 (method 2 is a script), then `jstracker` (a script).
    static func impression(_ ad: NativeAd, factory: TrackerRequestFactory) -> [TrackerRequest] {
        var requests: [TrackerRequest] = []
        for (index, url) in ad.impressionTrackers.enumerated() {
            requests.append(factory.url(url, category: .impression, trigger: "impression", source: factory.source("native", "imptrackers[\(index)]")))
        }
        requests += eventTrackers(ad, event: impressionEvent, category: .impression, trigger: "impression", factory: factory)
        if let script = ad.jsTracker, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requests.append(factory.script(script, category: .impression, trigger: "impression (jstracker)", source: factory.source("native", "jstracker")))
        }
        return requests
    }

    /// `.viewable(level)`: `eventtrackers` with event 2 / 3 / 4.
    static func viewable(_ ad: NativeAd, level: ViewabilityLevel, factory: TrackerRequestFactory) -> [TrackerRequest] {
        eventTrackers(ad, event: eventType(for: level), category: .viewability, trigger: ViewabilityLabels.trigger(level), factory: factory)
    }

    /// `.click(assetID:)`: one link object applies (Native 1.2 §5.4 Asset Response `link`: "If there is no link object on
    /// the asset, the parent link object on the bid response applies"). A clicked asset with its own `link` uses only that
    /// link — its `clicktrackers`, its `url` and its `fallback`; any other click uses the ad's main link. Its trackers
    /// fire, then one navigation to its `url`, noting the deep-link `fallback` (none when the `url` is blank).
    static func click(_ ad: NativeAd, assetID: Int?, factory: TrackerRequestFactory) -> [TrackerRequest] {
        let asset = assetID.flatMap { id in ad.assets.first { $0.id == id } }
        let link: AdLink
        let linkPath: [String]
        if let asset, let assetLink = asset.link {
            link = assetLink
            linkPath = ["native", "asset \(asset.id)", "link"]
        } else {
            link = ad.link
            linkPath = ["native", "link"]
        }
        let trackers = link.clickTrackers.enumerated().map { index, url in
            (template: url, source: ([factory.root] + linkPath + ["clicktrackers[\(index)]"]).joined(separator: " › "))
        }
        return factory.click(trackers: trackers, destination: link.url, fallback: link.fallback,
                             destinationSource: ([factory.root] + linkPath).joined(separator: " › "))
    }

    private static func eventTrackers(_ ad: NativeAd, event: Int, category: TrackerCategory, trigger: String,
                                      factory: TrackerRequestFactory) -> [TrackerRequest] {
        var requests: [TrackerRequest] = []
        for (index, tracker) in ad.eventTrackers.enumerated() where tracker.event == event {
            requests.append(factory.url(tracker.url, category: category, trigger: trigger, source: factory.source("native", "eventtrackers[\(index)]"),
                                        isScript: tracker.method == 2))
        }
        return requests
    }
}

/// Trigger labels shared by the Native and AdCOM viewability trackers.
enum ViewabilityLabels {
    static func trigger(_ level: ViewabilityLevel) -> String {
        switch level {
        case .mrc50: "viewable MRC 50%"
        case .mrc100: "viewable MRC 100%"
        case .video50: "viewable video 50%"
        }
    }
}
