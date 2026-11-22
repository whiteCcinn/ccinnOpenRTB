import AppKit
import SwiftUI

/// The library: find a saved request, open it (with its response), render its saved response, duplicate or delete it,
/// and sort requests into groups (a section each, folded or not). A plain click opens; ⌘-click, ⇧-click and ⌘A select
/// several, which the Delete key, the context menu or the footer delete or move together. Opening over unsaved
/// changes, deleting and removing a group ask first.
struct SavedRequestsPopover: View {
    /// A saved request waiting for the user to discard the draft's changes.
    private struct PendingOpen {
        var saved: SavedRequest
        var render: Bool
    }

    /// A group name being typed: for a new group the requests go to, or a group's new name.
    private enum GroupEdit {
        case create([SavedRequest])
        case rename(SavedRequestGroups.Section)

        var title: String {
            switch self {
            case .create: "New Group"
            case .rename: "Rename Group"
            }
        }

        var action: String {
            switch self {
            case .create: "Move"
            case .rename: "Rename"
            }
        }

        var message: String {
            switch self {
            case let .create(requests):
                requests.count == 1 ? "“\(requests[0].name)” moves to the new group." : "The \(requests.count) requests move to the new group."
            case let .rename(section):
                "Every request in “\(section.title)” takes the new name. A name another group has merges the two."
            }
        }
    }

    let client: ClientModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection: Set<UUID>
    @State private var pendingOpen: PendingOpen?
    /// The requests waiting for the user to confirm their deletion (never empty).
    @State private var pendingDelete: [SavedRequest]?
    @State private var groupEdit: GroupEdit?
    @State private var groupName = ""
    @State private var pendingRemoval: SavedRequestGroups.Section?
    /// Folded sections (`SavedRequestGroups.encodeCollapsed`), the same in every window and across launches.
    @AppStorage("SavedRequests.collapsedGroups") private var collapsedText = ""

    init(client: ClientModel, isPresented: Binding<Bool>, selection: Set<UUID> = []) {
        self.client = client
        _isPresented = isPresented
        _selection = State(initialValue: selection)
    }

    private var library: SavedRequestLibrary { client.library }
    private var collapsed: Set<String> { SavedRequestGroups.decodeCollapsed(collapsedText) }

    // The body is split into functions that each type-check alone: as one expression, the panel with its four dialogs
    // took 314 ms locally and timed out on CI's Swift 6.2.
    var body: some View {
        let listing = SavedRequestGroups.listing(library.requests, query: query, collapsed: collapsed)
        let groupNames = SavedRequestGroups.names(library.requests)
        return namingGroups(askingToRemoveGroups(askingToDelete(askingToOpen(panel(listing, groupNames: groupNames)))))
    }

    private func panel(_ listing: SavedRequestGroups.Listing, groupNames: [String]) -> some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query, prompt: Text("Name, group, method or URL"))
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            SavedRequestsList(listing: listing, currentID: client.savedID, selection: $selection,
                              isEmptyLibrary: library.requests.isEmpty, isLoaded: library.isLoaded,
                              actions: requestActions(groupNames), groupActions: groupActions)
            Divider()
            SavedRequestsFooter(library: library, selection: selectionBar(listing, groupNames: groupNames))
        }
        .frame(width: 380, height: 440)
        .task { await library.loadIfNeeded() }
        .onChange(of: listing.shown.map(\.id)) { prune(to: listing.shown) }
    }

    private func askingToOpen(_ content: some View) -> some View {
        content.confirmationDialog("Discard the unsaved changes?", isPresented: Self.presence($pendingOpen), presenting: pendingOpen) { pending in
            Button("Open “\(pending.saved.name)”", role: .destructive) { open(pending.saved, render: pending.render) }
        } message: { _ in
            Text("The request in the Client tab has changes that are not saved.")
        }
    }

    private func askingToDelete(_ content: some View) -> some View {
        let confirmation = pendingDelete.map(SavedRequestSelection.confirmation(deleting:))
        return content.confirmationDialog(confirmation?.title ?? "", isPresented: Self.presence($pendingDelete), presenting: pendingDelete) { requests in
            Button(confirmation?.button ?? "Delete", role: .destructive) { delete(requests) }
        } message: { _ in
            Text(confirmation?.message ?? "")
        }
    }

    private func askingToRemoveGroups(_ content: some View) -> some View {
        let title = "Remove the group “\(pendingRemoval?.title ?? "")”?"
        return content.confirmationDialog(title, isPresented: Self.presence($pendingRemoval), presenting: pendingRemoval) { section in
            Button("Remove Group", role: .destructive) { removeGroup(section) }
        } message: { section in
            Text(removalMessage(section))
        }
    }

    private func namingGroups(_ content: some View) -> some View {
        content.alert(groupEdit?.title ?? "", isPresented: Self.presence($groupEdit), presenting: groupEdit) { edit in
            TextField("Group name", text: $groupName)
            Button(edit.action) { commit(edit) }
            Button("Cancel", role: .cancel) {}
        } message: { edit in
            Text(edit.message)
        }
    }

    /// Presented while `value` holds something; dismissing clears it.
    private static func presence<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    /// Counts every member, not only those a search shows: the whole group goes.
    private func removalMessage(_ section: SavedRequestGroups.Section) -> String {
        let count = library.requests.lazy.filter { SavedRequestGroups.key($0.group) == section.key }.count
        return count == 1 ? "Its request stays, under No Group." : "Its \(count) requests stay, under No Group."
    }

    private func prune(to shown: [SavedRequest]) {
        let kept = SavedRequestSelection.pruned(selection, to: shown)
        if kept != selection { selection = kept }
    }

    private func requestActions(_ groupNames: [String]) -> SavedRequestActions {
        SavedRequestActions(open: { request(open: $0, render: false) }, render: { request(open: $0, render: true) },
                            duplicate: { saved in Task { _ = await library.duplicate(saved.id) } }, delete: { pendingDelete = $0 },
                            move: move, newGroup: { edit(.create($0), name: "") },
                            groupNames: groupNames)
    }

    private var groupActions: SavedGroupActions {
        SavedGroupActions(toggle: { setCollapsed(SavedRequestGroups.toggled($0.id, in: collapsed, library: library.requests)) },
                          selectAll: selectAll(in:), rename: { edit(.rename($0), name: $0.title) }, remove: { pendingRemoval = $0 })
    }

    private func selectionBar(_ listing: SavedRequestGroups.Listing, groupNames: [String]) -> SelectionBar? {
        let targets = SavedRequestSelection.targets(selection, in: listing.shown)
        guard !targets.isEmpty else { return nil }
        return SelectionBar(selected: targets.count, listed: listing.shown.count, selectAll: { selection = Set(listing.shown.map(\.id)) },
                            deselect: { selection = [] }, delete: { pendingDelete = targets },
                            move: MoveToGroupMenu(title: "Move to", targets: targets, groupNames: groupNames,
                                                  move: move, newGroup: { edit(.create($0), name: "") }, asLink: true))
    }

    /// Opens at once when nothing would be lost, else asks (rendering a saved response opens it too).
    private func request(open saved: SavedRequest, render: Bool) {
        if client.hasUnsavedChanges {
            pendingOpen = PendingOpen(saved: saved, render: render)
            return
        }
        open(saved, render: render)
    }

    private func open(_ saved: SavedRequest, render: Bool) {
        client.open(saved)
        isPresented = false
        if render { Task { await client.render() } }
    }

    /// Deletes together. What was deleted leaves the list and so the selection (`pruned`); what could not be stays listed
    /// and selected, with the reason in the footer.
    private func delete(_ requests: [SavedRequest]) {
        let ids = Set(requests.map(\.id))
        Task { await client.deleteSaved(ids) }
    }

    private func move(_ requests: [SavedRequest], to group: String?) {
        let ids = Set(requests.map(\.id))
        Task { await library.move(ids, toGroup: group) }
    }

    private func edit(_ edit: GroupEdit, name: String) {
        groupName = name
        groupEdit = edit
    }

    /// A blank name does nothing (removing a group has its own command, which asks first).
    private func commit(_ edit: GroupEdit) {
        let name = groupName
        guard let key = SavedRequestGroups.key(name) else { return }
        switch edit {
        case let .create(requests):
            move(requests, to: name)
        case let .rename(section):
            guard let oldKey = section.key else { return }
            // The fold travels with the group.
            if collapsed.contains(section.id) {
                var next = collapsed
                next.remove(section.id)
                next.insert(SavedRequestGroups.Section.id(key: key))
                setCollapsed(next)
            }
            Task { await library.renameGroup(oldKey, to: name) }
        }
    }

    private func removeGroup(_ section: SavedRequestGroups.Section) {
        guard let key = section.key else { return }
        var next = collapsed
        next.remove(section.id)
        setCollapsed(next)
        Task { await library.renameGroup(key, to: nil) }
    }

    /// Unfolds the section and selects exactly its requests.
    private func selectAll(in section: SavedRequestGroups.Section) {
        if collapsed.contains(section.id) {
            var next = collapsed
            next.remove(section.id)
            setCollapsed(next)
        }
        selection = Set(section.requests.map(\.id))
    }

    private func setCollapsed(_ ids: Set<String>) {
        collapsedText = SavedRequestGroups.encodeCollapsed(ids)
    }
}

/// What a row (or the selection) can do.
private struct SavedRequestActions {
    var open: (SavedRequest) -> Void
    var render: (SavedRequest) -> Void
    var duplicate: (SavedRequest) -> Void
    var delete: ([SavedRequest]) -> Void
    var move: ([SavedRequest], String?) -> Void
    var newGroup: ([SavedRequest]) -> Void
    var groupNames: [String]
}

private struct SavedRequestsList: View {
    let listing: SavedRequestGroups.Listing
    let currentID: UUID?
    @Binding var selection: Set<UUID>
    let isEmptyLibrary: Bool
    let isLoaded: Bool
    let actions: SavedRequestActions
    let groupActions: SavedGroupActions

    var body: some View {
        if !isLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if listing.isEmpty {
            ContentUnavailableView(isEmptyLibrary ? "No Saved Requests" : "No Matches", systemImage: "tray",
                                   description: Text(isEmptyLibrary ? "Save a request and its response with ⌘S." : "Try other words."))
        } else {
            List(selection: $selection) {
                if let sections = listing.sections {
                    ForEach(sections) { section in
                        Section {
                            if listing.isExpanded(section) { rows(section.requests) }
                        } header: {
                            SavedGroupHeader(section: section, isExpanded: listing.isExpanded(section), canFold: !listing.expandAll,
                                             actions: groupActions)
                        }
                    }
                } else {
                    rows(listing.shown)
                }
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: UUID.self) { ids in
                menu(for: SavedRequestSelection.targets(ids, in: listing.shown))
            } primaryAction: { ids in
                // Return, or a double click.
                let targets = SavedRequestSelection.targets(ids, in: listing.shown)
                if targets.count == 1, let saved = targets.first { actions.open(saved) }
            }
            .onDeleteCommand {
                let targets = SavedRequestSelection.targets(selection, in: listing.shown)
                if !targets.isEmpty { actions.delete(targets) }
            }
        }
    }

    private func rows(_ requests: [SavedRequest]) -> some View {
        ForEach(requests) { saved in
            SavedRequestRow(saved: saved, isCurrent: saved.id == currentID)
                .contentShape(Rectangle())
                // Simultaneous, so the list still selects: ⌘/⇧-click select without opening.
                .simultaneousGesture(TapGesture().onEnded { if Self.isPlainClick { actions.open(saved) } })
        }
    }

    /// The clicked row's actions, or (right-clicking the selection) what applies to all of it.
    @ViewBuilder
    private func menu(for targets: [SavedRequest]) -> some View {
        if targets.count == 1, let saved = targets.first {
            Button("Open") { actions.open(saved) }
            Button("Render Saved Response") { actions.render(saved) }
                .disabled(saved.exchange?.response.carriesAResponseToRender != true)
            Button("Duplicate") { actions.duplicate(saved) }
            Divider()
        }
        if !targets.isEmpty {
            MoveToGroupMenu(title: "Move to Group", targets: targets, groupNames: actions.groupNames, move: actions.move,
                            newGroup: actions.newGroup)
            Divider()
            Button(SavedRequestSelection.deleteMenuTitle(count: targets.count), role: .destructive) { actions.delete(targets) }
        }
    }

    /// The activation being handled (a click, or VoiceOver) opens: no ⌘, ⇧ or ⌃ on a mouse click.
    @MainActor
    private static var isPlainClick: Bool {
        let event = NSApp.currentEvent
        return SavedRequestSelection.activationOpens(event?.type, modifiers: event?.modifierFlags ?? [])
    }
}

private struct SavedRequestRow: View {
    let saved: SavedRequest
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(saved.name).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                    if isCurrent { Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary) }
                }
                Text(ClientPresentation.requestLine(saved.request))
                    .font(Theme.monospacedSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let status = saved.exchange?.response.status {
                    Badge(text: ClientPresentation.statusText(status), color: ClientPresentation.statusTone(status).color)
                }
                Text(saved.updatedAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// What the footer offers while rows are selected.
private struct SelectionBar {
    var selected: Int
    var listed: Int
    var selectAll: () -> Void
    var deselect: () -> Void
    var delete: () -> Void
    var move: MoveToGroupMenu
}

private struct SavedRequestsFooter: View {
    let library: SavedRequestLibrary
    /// `nil` when nothing listed is selected.
    let selection: SelectionBar?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SavedRequestsStatus(library: library)
            HStack(spacing: 10) {
                if let selection {
                    selectionActions(selection)
                } else {
                    libraryActions
                }
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func selectionActions(_ selection: SelectionBar) -> some View {
        Text(SavedRequestSelection.summary(selected: selection.selected, listed: selection.listed)).foregroundStyle(.secondary)
        Spacer()
        Button("Select All", action: selection.selectAll)
            .disabled(selection.selected == selection.listed)
            .help("Select every listed request (⌘A)")
        Button("Deselect", action: selection.deselect)
        selection.move
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move the selected requests to a group, a new one, or out of theirs")
        Button("Delete…", role: .destructive, action: selection.delete)
            .foregroundStyle(.red)
            .help("Delete the selected requests and their saved responses (⌫)")
    }

    @ViewBuilder
    private var libraryActions: some View {
        Text("\(library.requests.count) saved").foregroundStyle(.secondary)
            .help("Click opens a request; ⌘-click or ⇧-click selects several")
        Spacer()
        Button("Import…") { SavedRequestTransfer.importArchive(into: library) }
            .help("Import an export from another Mac: every request in it, merged by id (a newer copy wins)")
        Button("Export All…") { SavedRequestTransfer.exportAll(from: library) }
            .disabled(library.requests.isEmpty)
            .help("Write every saved request and its response to one file, to import on another Mac")
        Button("Show Folder") { showFolder() }
    }

    private func showFolder() {
        let directory = library.directory
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([directory.deletingLastPathComponent()])
        }
    }
}

/// The library's last error or notice, and the files it could not read.
private struct SavedRequestsStatus: View {
    let library: SavedRequestLibrary

    var body: some View {
        if let error = library.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        if let notice = library.lastNotice {
            Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
        if !library.unreadableFiles.isEmpty {
            Label("\(library.unreadableFiles.count) file(s) in the folder could not be read and are not listed.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(library.unreadableFiles.joined(separator: "\n"))
        }
    }
}
