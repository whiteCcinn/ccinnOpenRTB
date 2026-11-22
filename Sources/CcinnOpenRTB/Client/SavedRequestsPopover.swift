import AppKit
import SwiftUI

/// The library: find a saved request, open it (with its response), render its saved response, duplicate or delete it.
/// A plain click opens; ⌘-click, ⇧-click and ⌘A select several, which the Delete key, the context menu or the footer
/// delete together. Opening over unsaved changes and deleting both ask first.
struct SavedRequestsPopover: View {
    /// A saved request waiting for the user to discard the draft's changes.
    private struct PendingOpen {
        var saved: SavedRequest
        var render: Bool
    }

    let client: ClientModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection: Set<UUID>
    @State private var pendingOpen: PendingOpen?
    /// The requests waiting for the user to confirm their deletion (never empty).
    @State private var pendingDelete: [SavedRequest]?

    init(client: ClientModel, isPresented: Binding<Bool>, selection: Set<UUID> = []) {
        self.client = client
        _isPresented = isPresented
        _selection = State(initialValue: selection)
    }

    private var library: SavedRequestLibrary { client.library }

    var body: some View {
        let listed = ClientPresentation.filter(library.requests, by: query)
        let targets = SavedRequestSelection.targets(selection, in: listed)
        VStack(spacing: 0) {
            TextField("Search", text: $query, prompt: Text("Name, method or URL"))
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            SavedRequestsList(requests: listed, currentID: client.savedID, selection: $selection,
                              isEmptyLibrary: library.requests.isEmpty, isLoaded: library.isLoaded,
                              open: { request(open: $0, render: false) }, render: { request(open: $0, render: true) },
                              duplicate: { saved in Task { _ = await library.duplicate(saved.id) } }, delete: { pendingDelete = $0 })
            Divider()
            SavedRequestsFooter(library: library, selection: targets.isEmpty ? nil : SelectionBar(
                selected: targets.count, listed: listed.count, selectAll: { selection = Set(listed.map(\.id)) },
                deselect: { selection = [] }, delete: { pendingDelete = targets }))
        }
        .frame(width: 380, height: 440)
        .task { await library.loadIfNeeded() }
        .onChange(of: listed.map(\.id)) {
            let kept = SavedRequestSelection.pruned(selection, to: listed)
            if kept != selection { selection = kept }
        }
        .confirmationDialog("Discard the unsaved changes?", isPresented: Binding(get: { pendingOpen != nil }, set: { if !$0 { pendingOpen = nil } }),
                            presenting: pendingOpen) { pending in
            Button("Open “\(pending.saved.name)”", role: .destructive) { open(pending.saved, render: pending.render) }
        } message: { _ in
            Text("The request in the Client tab has changes that are not saved.")
        }
        .confirmationDialog(pendingDelete.map { SavedRequestSelection.confirmation(deleting: $0).title } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { requests in
            Button(SavedRequestSelection.confirmation(deleting: requests).button, role: .destructive) { delete(requests) }
        } message: { requests in
            Text(SavedRequestSelection.confirmation(deleting: requests).message)
        }
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
}

private struct SavedRequestsList: View {
    let requests: [SavedRequest]
    let currentID: UUID?
    @Binding var selection: Set<UUID>
    let isEmptyLibrary: Bool
    let isLoaded: Bool
    let open: (SavedRequest) -> Void
    let render: (SavedRequest) -> Void
    let duplicate: (SavedRequest) -> Void
    let delete: ([SavedRequest]) -> Void

    var body: some View {
        if !isLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if requests.isEmpty {
            ContentUnavailableView(isEmptyLibrary ? "No Saved Requests" : "No Matches", systemImage: "tray",
                                   description: Text(isEmptyLibrary ? "Save a request and its response with ⌘S." : "Try other words."))
        } else {
            List(requests, selection: $selection) { saved in
                SavedRequestRow(saved: saved, isCurrent: saved.id == currentID)
                    .contentShape(Rectangle())
                    // Simultaneous, so the list still selects: ⌘/⇧-click select without opening.
                    .simultaneousGesture(TapGesture().onEnded { if Self.isPlainClick { open(saved) } })
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: UUID.self) { ids in
                menu(for: SavedRequestSelection.targets(ids, in: requests))
            } primaryAction: { ids in
                // Return, or a double click.
                let targets = SavedRequestSelection.targets(ids, in: requests)
                if targets.count == 1, let saved = targets.first { open(saved) }
            }
            .onDeleteCommand {
                let targets = SavedRequestSelection.targets(selection, in: requests)
                if !targets.isEmpty { delete(targets) }
            }
        }
    }

    /// The clicked row's actions, or (right-clicking the selection) what applies to all of it.
    @ViewBuilder
    private func menu(for targets: [SavedRequest]) -> some View {
        if targets.count == 1, let saved = targets.first {
            Button("Open") { open(saved) }
            Button("Render Saved Response") { render(saved) }
                .disabled(saved.exchange?.response.carriesAResponseToRender != true)
            Button("Duplicate") { duplicate(saved) }
            Divider()
        }
        if !targets.isEmpty {
            Button(SavedRequestSelection.deleteMenuTitle(count: targets.count), role: .destructive) { delete(targets) }
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
