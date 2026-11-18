import AppKit
import CcinnOpenRTBKit
import RTBKit
import SwiftUI
import UniformTypeIdentifiers

/// View state of the Network window (independent of which monitor it shows).
@MainActor
@Observable
final class NetworkWindowModel {
    enum Layout: String, CaseIterable, Identifiable {
        case list = "List"
        case tree = "Tree"
        case waterfall = "Waterfall"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .list: "list.bullet"
            case .tree: "list.bullet.indent"
            case .waterfall: "chart.bar.xaxis"
            }
        }
    }

    var layout: Layout = .list
    var filter = NetworkFilter()
    var selection: UUID?
    var followTail = true
    var exportError: String?

    func toggle(_ category: TrackerCategory) {
        if filter.categories.contains(category) { filter.categories.remove(category) } else { filter.categories.insert(category) }
    }

    func toggle(_ delivery: NetworkDelivery) {
        if filter.deliveries.contains(delivery) { filter.deliveries.remove(delivery) } else { filter.deliveries.insert(delivery) }
    }
}

/// Root of the Network window.
struct NetworkWindowView: View {
    var registry = NetworkRegistry.shared
    @State private var model = NetworkWindowModel()

    var body: some View {
        Group {
            if let monitor = registry.activeMonitor {
                NetworkMonitorView(monitor: monitor, model: model)
                    .id(ObjectIdentifier(monitor))
            } else {
                ContentUnavailableView {
                    Label("No Simulator Window", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("Open a CcinnOpenRTB window. The Network window shows the requests of the window you last used.")
                }
            }
        }
        .frame(minWidth: 860, minHeight: 420)
    }
}

/// The monitor's requests: list, tree or waterfall, with details beside them.
struct NetworkMonitorView: View {
    let monitor: NetworkMonitor
    @Bindable var model: NetworkWindowModel

    var body: some View {
        let all = monitor.entries
        let visible = model.filter.apply(all)
        let origin = all.first?.startedAt
        VStack(spacing: 0) {
            HSplitView {
                content(visible, all: all, origin: origin)
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                if let id = model.selection, let entry = all.first(where: { $0.id == id }) {
                    NetworkDetailView(entry: entry, entries: all, origin: origin, monitor: monitor) { model.selection = $0 }
                        .frame(minWidth: 320, idealWidth: 380, maxWidth: 480, maxHeight: .infinity)
                }
            }
            Divider()
            NetworkStatusBar(monitor: monitor, all: all, visible: visible.count)
        }
        .environment(\.shownNetworkMonitor, monitor)
        .searchable(text: $model.filter.text, placement: .toolbar, prompt: "Filter URL, trigger, source, status")
        .toolbar { toolbar(all: all) }
        .navigationTitle("Network")
        .navigationSubtitle(NetworkPresentation.session(mode: monitor.mode, offline: monitor.offline).subtitle)
        .onAppear {
            if let layout = NetworkDemo.requestedLayout { model.layout = layout }
        }
        .onChange(of: all.count) {
            // `--network-select <sequence>` (snapshots): select that request once it exists.
            if model.selection == nil, let sequence = NetworkDemo.requestedSelection, let entry = all.first(where: { $0.sequence == sequence }) {
                model.selection = entry.id
            }
        }
        .alert("Could not export HAR", isPresented: Binding(get: { model.exportError != nil }, set: { if !$0 { model.exportError = nil } })) {
            Button("OK") { model.exportError = nil }
        } message: {
            Text(model.exportError ?? "")
        }
    }

    @ViewBuilder
    private func content(_ visible: [NetworkEntry], all: [NetworkEntry], origin: Date?) -> some View {
        if all.isEmpty {
            ContentUnavailableView {
                Label("No Requests Yet", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Render a bid: win and billing notices, impressions, VAST events, clicks and content fetches appear here as they happen.")
            }
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: model.filter.text)
        } else {
            switch model.layout {
            case .list:
                NetworkTableView(entries: visible, origin: origin, selection: $model.selection, followTail: model.followTail)
            case .tree:
                NetworkTreeView(entries: visible, origin: origin, selection: $model.selection, followTail: model.followTail)
            case .waterfall:
                NetworkWaterfallView(entries: visible, selection: $model.selection, followTail: model.followTail)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(all: [NetworkEntry]) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Layout", selection: $model.layout) {
                ForEach(NetworkWindowModel.Layout.allCases) { layout in
                    Label(layout.rawValue, systemImage: layout.systemImage).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .help("List, relationship tree or waterfall timeline")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Section("Category") {
                    ForEach(TrackerCategory.allCases, id: \.self) { category in
                        Toggle(Theme.label(for: category), isOn: Binding(get: { model.filter.categories.contains(category) },
                                                                          set: { _ in model.toggle(category) }))
                    }
                }
                Section("Mode") {
                    ForEach(NetworkDelivery.allCases, id: \.self) { delivery in
                        Toggle(delivery.label, isOn: Binding(get: { model.filter.deliveries.contains(delivery) }, set: { _ in model.toggle(delivery) }))
                    }
                }
                Divider()
                Toggle("Failures Only", isOn: $model.filter.failuresOnly)
                Button("Show All") { model.filter = NetworkFilter(text: model.filter.text) }
                    .disabled(model.filter.categories.isEmpty && model.filter.deliveries.isEmpty && !model.filter.failuresOnly)
            } label: {
                Label("Filter", systemImage: model.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Filter by category and mode")

            Toggle(isOn: $model.followTail) {
                Label("Follow", systemImage: "arrow.down.to.line")
            }
            .help("Keep the newest request in view")

            Button {
                monitor.clear()
                model.selection = nil
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Clear the log (⌘K)")
            .disabled(all.isEmpty)

            Button {
                exportHAR()
            } label: {
                Label("Export HAR", systemImage: "square.and.arrow.up")
            }
            .help("Export every request as HAR 1.2")
            .disabled(all.isEmpty)
        }
    }

    private func exportHAR() {
        let snapshot = monitor.harSnapshot()
        let panel = NSSavePanel()
        panel.title = "Export HAR"
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "CcinnOpenRTB-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))-\(snapshot.entries.count).har"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let model = model
        Task {
            do {
                // Encoding thousands of entries happens off the main actor.
                try await Task.detached(priority: .userInitiated) {
                    let data = try HARExporter.data(entries: snapshot.entries, bodies: snapshot.bodies, requestBodies: snapshot.requestBodies)
                    try data.write(to: url, options: .atomic)
                }.value
            } catch {
                model.exportError = error.localizedDescription
            }
        }
    }
}

/// Counts and the session mode under the list.
private struct NetworkStatusBar: View {
    let monitor: NetworkMonitor
    let all: [NetworkEntry]
    let visible: Int

    var body: some View {
        let counts = Dictionary(grouping: all, by: \.delivery).mapValues(\.count)
        HStack(spacing: 12) {
            Text(visible == all.count ? "\(all.count.formatted()) requests" : "\(visible.formatted()) of \(all.count.formatted()) requests")
            ForEach(NetworkDelivery.allCases, id: \.self) { delivery in
                if let count = counts[delivery] {
                    Label("\(count.formatted()) \(delivery.label.lowercased())", systemImage: Theme.icon(for: delivery))
                        .foregroundStyle(Theme.color(for: delivery))
                }
            }
            if monitor.inFlightCount > 0 {
                Label("\(monitor.inFlightCount) in flight", systemImage: "arrow.triangle.2.circlepath")
            }
            Spacer()
            if all.count >= NetworkMonitor.defaultCapacity {
                Text("Oldest requests dropped (limit \(NetworkMonitor.defaultCapacity.formatted()))").foregroundStyle(.orange)
            }
            let session = NetworkPresentation.session(mode: monitor.mode, offline: monitor.offline)
            Badge(text: session.title, color: Theme.color(for: session.delivery), systemImage: session.systemImage)
                .help(session.subtitle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
