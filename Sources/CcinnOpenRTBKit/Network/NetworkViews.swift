import Foundation
import RTBKit

/// The Network window's filter: categories, deliveries (mode) and free text. Empty sets mean "all".
public struct NetworkFilter: Sendable, Hashable {
    public var categories: Set<TrackerCategory>
    public var deliveries: Set<NetworkDelivery>
    /// Matched case-insensitively against URL, template, trigger, source, status and note; words must all match.
    public var text: String
    public var failuresOnly: Bool

    public init(categories: Set<TrackerCategory> = [], deliveries: Set<NetworkDelivery> = [], text: String = "", failuresOnly: Bool = false) {
        self.categories = categories
        self.deliveries = deliveries
        self.text = text
        self.failuresOnly = failuresOnly
    }

    public var isActive: Bool {
        !categories.isEmpty || !deliveries.isEmpty || !words.isEmpty || failuresOnly
    }

    private var words: [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public func apply(_ entries: [NetworkEntry]) -> [NetworkEntry] {
        guard isActive else { return entries }
        let words = words
        return entries.filter { matches($0, words: words) }
    }

    public func matches(_ entry: NetworkEntry) -> Bool {
        matches(entry, words: words)
    }

    private func matches(_ entry: NetworkEntry, words: [String]) -> Bool {
        if !categories.isEmpty, !categories.contains(entry.category) { return false }
        if !deliveries.isEmpty, !deliveries.contains(entry.delivery) { return false }
        if failuresOnly, !entry.isFailure { return false }
        guard !words.isEmpty else { return true }
        let haystack = [entry.url, entry.template, entry.trigger, entry.source, entry.category.rawValue, entry.note ?? "",
                        entry.status.map(String.init) ?? "", entry.mimeType ?? ""].joined(separator: "\n").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

extension NetworkEntry {
    /// Failed, or answered with a 4xx/5xx status.
    public var isFailure: Bool {
        switch state {
        case .failed: true
        case let .completed(status): status >= 400
        default: false
        }
    }
}

/// One node of the relationship tree.
public struct NetworkTreeNode: Sendable, Hashable, Identifiable {
    public var entry: NetworkEntry
    /// `nil` for leaves (so outline views show no disclosure triangle).
    public var children: [NetworkTreeNode]?

    public var id: UUID { entry.id }
}

/// Builds the parent/child tree (wrapper chains, redirects, win-notice markup → creative loads, click → navigation).
public enum NetworkTree {
    /// Nesting deeper than this is flattened (the entry becomes a root): real chains are a few levels deep, and a
    /// bounded depth keeps building, comparing, rendering and freeing the tree far from the stack limit.
    public static let maxDepth = 32

    /// Roots in sequence order, children in sequence order. An entry whose parent is missing (filtered out, dropped) or
    /// does not come before it is a root, so cycles are impossible. Iterative, and depth is capped at `maxDepth`.
    public static func build(_ entries: [NetworkEntry]) -> [NetworkTreeNode] {
        var indexByID: [UUID: Int] = [:]
        for (index, entry) in entries.enumerated() { indexByID[entry.id] = index }
        var depth = [Int](repeating: 0, count: entries.count)
        var childrenByParent: [UUID: [Int]] = [:]
        var roots: [Int] = []
        // Parents precede children in sequence order, so each parent's depth is known before its children's.
        let order = entries.indices.sorted { entries[$0].sequence < entries[$1].sequence }
        for index in order {
            let entry = entries[index]
            if let parent = entry.parentID, let parentIndex = indexByID[parent], entries[parentIndex].sequence < entry.sequence,
               depth[parentIndex] + 1 < maxDepth {
                depth[index] = depth[parentIndex] + 1
                childrenByParent[parent, default: []].append(index)
            } else {
                roots.append(index)
            }
        }
        // Post-order without recursion: a node is built once all of its children are.
        var built: [Int: NetworkTreeNode] = [:]
        var stack: [(index: Int, expanded: Bool)] = roots.reversed().map { ($0, false) }
        while let (index, expanded) = stack.popLast() {
            let entry = entries[index]
            let childIndices = childrenByParent[entry.id] ?? []
            if expanded || childIndices.isEmpty {
                let children = childIndices.compactMap { built.removeValue(forKey: $0) }
                built[index] = NetworkTreeNode(entry: entry, children: children.isEmpty ? nil : children)
            } else {
                stack.append((index, true))
                for child in childIndices.reversed() { stack.append((child, false)) }
            }
        }
        return roots.compactMap { built[$0] }
    }

    /// The node ids from the root down to `id` (for expanding the outline to a selection).
    public static func ancestors(of id: UUID, in entries: [NetworkEntry]) -> [UUID] {
        var byID: [UUID: NetworkEntry] = [:]
        for entry in entries { byID[entry.id] = entry }
        var path: [UUID] = []
        var current = byID[id]
        while let entry = current, let parent = entry.parentID, let parentEntry = byID[parent], parentEntry.sequence < entry.sequence {
            path.append(parent)
            current = parentEntry
        }
        return path.reversed()
    }
}

/// Positions on the waterfall's shared time axis.
public struct WaterfallLayout: Sendable, Hashable {
    public struct Bar: Sendable, Hashable, Identifiable {
        public var id: UUID
        /// 0…1 from the axis origin.
        public var start: Double
        /// 0…1 of the axis; 0 for instantaneous records (simulated, blocked).
        public var length: Double
        public var isOpen: Bool
    }

    public var origin: Date
    /// Seconds covered by the axis (never below `minimumSpan`).
    public var span: TimeInterval
    public var bars: [Bar]

    public static let minimumSpan: TimeInterval = 1

    /// `now` closes the bars of pending entries.
    public static func compute(_ entries: [NetworkEntry], now: Date) -> WaterfallLayout {
        guard let origin = entries.map(\.startedAt).min() else {
            return WaterfallLayout(origin: now, span: minimumSpan, bars: [])
        }
        var end = origin
        for entry in entries {
            let finish = entry.finishedAt ?? (entry.state == .pending ? max(now, entry.startedAt) : entry.startedAt)
            end = max(end, finish)
        }
        let span = max(minimumSpan, end.timeIntervalSince(origin) * 1.05)
        let bars = entries.map { entry -> Bar in
            let start = entry.startedAt.timeIntervalSince(origin) / span
            let open = entry.state == .pending && entry.finishedAt == nil
            let finish = entry.finishedAt ?? (open ? max(now, entry.startedAt) : entry.startedAt)
            let length = max(0, finish.timeIntervalSince(entry.startedAt)) / span
            return Bar(id: entry.id, start: clamp(start), length: min(clamp(length), 1 - clamp(start)), isOpen: open)
        }
        return WaterfallLayout(origin: origin, span: span, bars: bars)
    }

    /// Tick marks (seconds from the origin) at a readable step.
    public func ticks(maximumCount: Int = 8) -> [TimeInterval] {
        let steps: [TimeInterval] = [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let target = span / Double(max(1, maximumCount))
        let step = steps.first { $0 >= target } ?? max(target.rounded(.up), 1)
        var ticks: [TimeInterval] = []
        var value = 0.0
        while value <= span, ticks.count < 200 {
            ticks.append(value)
            value += step
        }
        return ticks
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// Settings ▸ Network keys and defaults, shared by the Settings window and the session (app-shell).
public enum NetworkPreferences {
    public static let requestTimeoutKey = "network.requestTimeout"
    public static let openClickThroughsKey = "network.openClickThroughsInBrowser"
    public static let defaultRequestTimeout: TimeInterval = 15
    public static let requestTimeoutChoices: [TimeInterval] = [5, 10, 15, 30, 60]

    public static func requestTimeout(in defaults: UserDefaults) -> TimeInterval {
        let value = defaults.double(forKey: requestTimeoutKey)
        return value > 0 ? NetworkMonitor.clampedTimeout(value) : defaultRequestTimeout
    }

    public static func opensClickThroughs(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: openClickThroughsKey)
    }

    /// Whether a click-through leaves the simulator for the default browser: Real mode, the setting on (default off), a
    /// device that can navigate (never CTV), and an http(s) URL.
    public static func shouldOpenInBrowser(_ url: String, mode: TrackingMode, settingEnabled: Bool, device: DeviceProfile?) -> Bool {
        guard mode == .real, settingEnabled, device?.supportsClickThrough ?? true else { return false }
        let scheme = URLText.scheme(url)
        return scheme == "http" || scheme == "https"
    }
}
