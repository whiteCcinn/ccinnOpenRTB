import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// Cells shared by the list and the tree.
enum NetworkCells {
    static func sequence(_ entry: NetworkEntry) -> some View {
        Text("\(entry.sequence)").monospacedDigit().foregroundStyle(.secondary)
    }

    static func offset(_ entry: NetworkEntry, origin: Date?) -> some View {
        Text(origin.map { Format.offset(entry.startedAt.timeIntervalSince($0)) } ?? "—")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    static func url(_ entry: NetworkEntry) -> some View {
        HStack(spacing: 4) {
            if entry.isRedirectHop {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).imageScale(.small)
            }
            if entry.isScript {
                Image(systemName: "curlybraces").foregroundStyle(.secondary).imageScale(.small).help("Script tracker")
            }
            if !entry.unknownMacros.isEmpty {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color(nsColor: .macroUnknown)).imageScale(.small)
                    .help("Unknown macros: \(entry.unknownMacros.joined(separator: ", "))")
            }
            Text(URLText.hostAndPath(entry.url))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.url)
        }
    }

    /// The Mode badge already says "Blocked", so the narrow Status column shows a dash for it.
    static func status(_ entry: NetworkEntry) -> some View {
        Text(entry.state == .blocked ? "—" : Theme.statusText(for: entry))
            .monospacedDigit()
            .foregroundStyle(Theme.color(for: entry.state))
            .help(failureMessage(entry) ?? entry.note ?? "")
    }

    static func duration(_ entry: NetworkEntry) -> some View {
        Text(entry.state == .pending ? "…" : Format.duration(seconds: entry.duration))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    static func failureMessage(_ entry: NetworkEntry) -> String? {
        if case let .failed(message) = entry.state { return message }
        return nil
    }
}

/// Copy URL / Copy as curl for the selected rows.
@MainActor
struct NetworkContextMenu: View {
    let ids: Set<UUID>
    let entries: [NetworkEntry]
    @Environment(\.shownNetworkMonitor) private var monitor

    var body: some View {
        let selected = entries.filter { ids.contains($0.id) }
        Button(selected.count > 1 ? "Copy URLs" : "Copy URL") { Pasteboard.copy(selected.map(\.url).joined(separator: "\n")) }
            .disabled(selected.isEmpty)
        Button("Copy as curl") {
            Pasteboard.copy(selected.map { CurlCommand.make(for: $0, body: monitor?.requestBody(for: $0.id)) }.joined(separator: "\n"))
        }
        .disabled(selected.isEmpty)
        if selected.count == 1, let entry = selected.first, entry.template != entry.url {
            Button("Copy Template") { Pasteboard.copy(entry.template) }
        }
    }
}

extension EnvironmentValues {
    /// The monitor whose entries the Network window shows (its request bodies, for Copy as curl).
    @Entry var shownNetworkMonitor: NetworkMonitor?
}

/// The real-time list.
struct NetworkTableView: View {
    let entries: [NetworkEntry]
    let origin: Date?
    @Binding var selection: UUID?
    let followTail: Bool

    var body: some View {
        ScrollViewReader { proxy in
            Table(entries, selection: $selection) {
                TableColumn("#") { NetworkCells.sequence($0) }.width(min: 28, ideal: 36, max: 70)
                TableColumn("+ms") { NetworkCells.offset($0, origin: origin) }.width(min: 44, ideal: 56, max: 110)
                TableColumn("Category") { RequestCategoryBadge(entry: $0) }.width(min: 80, ideal: 100, max: 140)
                TableColumn("Trigger") { Text($0.trigger).lineLimit(1).help($0.source) }.width(min: 70, ideal: 118, max: 260)
                TableColumn("URL") { NetworkCells.url($0) }.width(min: 100, ideal: 180)
                TableColumn("Mode") { DeliveryBadge(delivery: $0.delivery) }.width(min: 70, ideal: 88, max: 120)
                TableColumn("Status") { NetworkCells.status($0) }.width(min: 40, ideal: 52, max: 90)
                TableColumn("Duration") { NetworkCells.duration($0) }.width(min: 48, ideal: 62, max: 100)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                NetworkContextMenu(ids: ids, entries: entries)
            }
            .onChange(of: entries.last?.id) { _, last in
                guard followTail, let last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .onAppear {
                if followTail, let last = entries.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

/// The relationship tree: wrapper chains, redirects, win-notice markup → creative loads, click → navigation.
struct NetworkTreeView: View {
    let entries: [NetworkEntry]
    let origin: Date?
    @Binding var selection: UUID?
    let followTail: Bool

    var body: some View {
        let nodes = NetworkTree.build(entries)
        ScrollViewReader { proxy in
            Table(nodes, children: \.children, selection: $selection) {
                TableColumn("Request") { node in
                    HStack(spacing: 6) {
                        NetworkCells.sequence(node.entry)
                        RequestCategoryBadge(entry: node.entry)
                        Text(node.entry.trigger).lineLimit(1)
                    }
                    .help(node.entry.source)
                }
                .width(min: 180, ideal: 250)
                TableColumn("+ms") { NetworkCells.offset($0.entry, origin: origin) }.width(min: 44, ideal: 56, max: 110)
                TableColumn("URL") { NetworkCells.url($0.entry) }.width(min: 100, ideal: 170)
                TableColumn("Mode") { DeliveryBadge(delivery: $0.entry.delivery) }.width(min: 70, ideal: 88, max: 120)
                TableColumn("Status") { NetworkCells.status($0.entry) }.width(min: 40, ideal: 52, max: 90)
                TableColumn("Duration") { NetworkCells.duration($0.entry) }.width(min: 48, ideal: 62, max: 100)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                NetworkContextMenu(ids: ids, entries: entries)
            }
            .onChange(of: nodes.last?.id) { _, last in
                guard followTail, let last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }
}

/// Bars on a shared time axis, one row per request in sequence order.
struct NetworkWaterfallView: View {
    let entries: [NetworkEntry]
    @Binding var selection: UUID?
    let followTail: Bool

    private static let labelWidth: CGFloat = 250
    private static let rowHeight: CGFloat = 22

    var body: some View {
        let hasPending = entries.contains { $0.state == .pending }
        TimelineView(.periodic(from: .now, by: hasPending ? 0.25 : 3_600)) { context in
            let layout = WaterfallLayout.compute(entries, now: context.date)
            VStack(spacing: 0) {
                header(layout)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(zip(entries, layout.bars)), id: \.0.id) { entry, bar in
                                row(entry, bar: bar, layout: layout)
                                    .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: entries.last?.id) { _, last in
                        guard followTail, let last else { return }
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func header(_ layout: WaterfallLayout) -> some View {
        HStack(spacing: 0) {
            Text("Request").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
                .padding(.leading, 8)
            GeometryReader { geometry in
                ForEach(layout.ticks(), id: \.self) { tick in
                    Text(tick == 0 ? "0" : Format.duration(seconds: tick))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: geometry.size.width * tick / layout.span + 2, y: 4)
                }
            }
        }
        .frame(height: 22)
    }

    private func row(_ entry: NetworkEntry, bar: WaterfallLayout.Bar, layout: WaterfallLayout) -> some View {
        let selected = selection == entry.id
        let color = Theme.color(for: entry.category)
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(entry.sequence)").monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                Image(systemName: Theme.icon(for: entry.category)).foregroundStyle(color).frame(width: 14)
                Text(entry.trigger).lineLimit(1)
                Text(URLText.host(entry.url) ?? "").lineLimit(1).foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(width: Self.labelWidth, alignment: .leading)
            .padding(.leading, 4)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    ForEach(layout.ticks(), id: \.self) { tick in
                        Rectangle().fill(.separator.opacity(0.35)).frame(width: 0.5)
                            .offset(x: width * tick / layout.span)
                    }
                    let start = width * bar.start
                    let length = width * bar.length
                    if length < 3 {
                        Image(systemName: entry.state == .simulated || entry.state == .blocked ? "diamond" : "diamond.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(color)
                            .offset(x: max(0, start - 4))
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.opacity(bar.isOpen ? 0.45 : 0.85))
                            .frame(width: length, height: 10)
                            .offset(x: start)
                    }
                    if entry.state == .pending || entry.duration != nil {
                        Text(entry.state == .pending ? "…" : Format.duration(seconds: entry.duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: min(width - 50, start + max(length, 6) + 4))
                    }
                }
                .frame(height: Self.rowHeight)
            }
        }
        .frame(height: Self.rowHeight)
        .background(selected ? Theme.accent.opacity(0.18) : (entry.sequence.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selection = entry.id }
        .contextMenu { NetworkContextMenu(ids: [entry.id], entries: [entry]) }
        .help("\(entry.trigger) · \(entry.url)")
    }
}
