import SwiftUI

/// What a section header can do with its group.
struct SavedGroupActions {
    var toggle: (SavedRequestGroups.Section) -> Void
    var selectAll: (SavedRequestGroups.Section) -> Void
    var rename: (SavedRequestGroups.Section) -> Void
    var remove: (SavedRequestGroups.Section) -> Void
}

/// Moving requests: to an existing group, a new one, or out of theirs. In a row's context menu and the selection footer.
struct MoveToGroupMenu: View {
    let title: String
    let targets: [SavedRequest]
    let groupNames: [String]
    let move: ([SavedRequest], String?) -> Void
    let newGroup: ([SavedRequest]) -> Void

    /// Drawn as a link (the footer) rather than a menu item's title.
    var asLink = false

    var body: some View {
        Menu {
            items
        } label: {
            if asLink {
                HStack(spacing: 2) {
                    Text(title)
                    Image(systemName: "chevron.down").imageScale(.small)
                }
                .foregroundStyle(Color.accentColor)
            } else {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private var items: some View {
        ForEach(groupNames, id: \.self) { name in
            let key = SavedRequestGroups.key(name)
            Button(name) { move(targets, name) }
                .disabled(targets.allSatisfy { SavedRequestGroups.key($0.group) == key })
        }
        if !groupNames.isEmpty { Divider() }
        Button("New Group…") { newGroup(targets) }
        if targets.contains(where: { SavedRequestGroups.key($0.group) != nil }) {
            Divider()
            Button("Remove from Group") { move(targets, nil) }
        }
    }
}

/// A section's header: the whole title folds and unfolds it (not while searching: every match shows); the menu holds
/// the group's actions.
struct SavedGroupHeader: View {
    let section: SavedRequestGroups.Section
    let isExpanded: Bool
    let canFold: Bool
    let actions: SavedGroupActions

    var body: some View {
        HStack(spacing: 6) {
            Button { actions.toggle(section) } label: {
                SavedGroupTitle(section: section, isExpanded: isExpanded, canFold: canFold)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(canFold)
            .help(canFold ? (isExpanded ? "Fold this group" : "Unfold this group") : "Every match is shown while searching")
            Menu {
                Button(section.key == nil ? "Select All Ungrouped" : "Select All in Group") { actions.selectAll(section) }
                if section.key != nil {
                    Divider()
                    Button("Rename Group…") { actions.rename(section) }
                    Button("Remove Group…") { actions.remove(section) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Group actions")
        }
    }
}

private struct SavedGroupTitle: View {
    let section: SavedRequestGroups.Section
    let isExpanded: Bool
    let canFold: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(canFold ? .secondary : .quaternary)
                .frame(width: 10)
            Image(systemName: section.key == nil ? "tray" : "folder").foregroundStyle(.secondary)
            Text(section.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            Text("\(section.requests.count)").foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
