import RTBKit
import SwiftUI

/// The Inspector: the selected bid as an outline (bid → markup → Native assets / VAST chain → creatives → trackers) with
/// its issues, or its markup formatted.
struct InspectorPane: View {
    enum Mode: String {
        case outline, markup
    }

    let session: AdSession
    @SceneStorage("inspector.mode") private var mode: Mode = .outline

    var body: some View {
        if let candidate = session.selectedCandidate {
            inspector(candidate, rendered: session.prepared?.candidate.id == candidate.id ? session.prepared : nil)
        } else {
            ContentUnavailableView {
                Label("No Bid Selected", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Paste a response or pick a sample. The Inspector shows the selected bid's markup, Native assets, VAST chain and trackers.")
            }
        }
    }

    private func inspector(_ candidate: AdCandidate, rendered: PreparedAd?) -> some View {
        VStack(spacing: 0) {
            modePicker
            Divider()
            switch mode {
            case .outline:
                outline(candidate: candidate, rendered: rendered)
            case .markup:
                InspectorMarkupView(candidate: rendered?.candidate ?? candidate, deviceMarkup: rendered?.deviceMarkup)
            }
        }
    }

    private var modePicker: some View {
        HStack {
            Picker("Inspector", selection: $mode) {
                Text("Outline").tag(Mode.outline)
                Text("Markup").tag(Mode.markup)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("The bid as an outline, or its markup (VAST, Native JSON, HTML) formatted")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func outline(candidate: AdCandidate, rendered: PreparedAd?) -> some View {
        let nodes = InspectorTree.build(candidate: rendered?.candidate ?? candidate, native: rendered?.native ?? session.inspectedNative,
                                        vastDocument: session.inspectedVAST, resolved: rendered?.vast)
        return VSplitView {
            List(nodes, children: \.children) { node in
                InspectorRow(node: node)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 160, maxHeight: .infinity)
            let contentHosts = session.contactedContentHosts
            if !contentHosts.isEmpty {
                ScrollView {
                    ContentHostsSection(hosts: contentHosts).padding(10)
                }
                .frame(minHeight: 60, idealHeight: 110, maxHeight: 220)
            }
            if !session.issues.isEmpty {
                IssuesList(issues: session.issues)
                    .frame(minHeight: 80, idealHeight: 180, maxHeight: 360)
            }
        }
    }
}

private struct InspectorRow: View {
    let node: InspectorNode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: node.symbol)
                .font(.caption)
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            Text(node.title).fontWeight(node.children == nil ? .regular : .medium)
            if let detail = node.detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.monospacedSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .help(node.detail ?? node.title)
        .contextMenu {
            if let detail = node.detail { Button("Copy Value") { Pasteboard.copy(detail) } }
            Button("Copy Title") { Pasteboard.copy(node.title) }
        }
    }
}
