import RTBKit
import SwiftUI

/// The Inspector: the selected bid as an outline (bid → markup → Native assets / VAST chain → creatives → trackers), then
/// its issues.
struct InspectorPane: View {
    let session: AdSession

    var body: some View {
        if let candidate = session.selectedCandidate {
            let rendered = session.prepared?.candidate.id == candidate.id ? session.prepared : nil
            let nodes = InspectorTree.build(candidate: rendered?.candidate ?? candidate, native: rendered?.native ?? session.inspectedNative,
                                            vastDocument: session.inspectedVAST, resolved: rendered?.vast)
            VSplitView {
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
        } else {
            ContentUnavailableView {
                Label("No Bid Selected", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Paste a response or pick a sample. The Inspector shows the selected bid's markup, Native assets, VAST chain and trackers.")
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
