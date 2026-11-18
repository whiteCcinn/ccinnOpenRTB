import AppKit
import SwiftUI

/// The library: find a saved request, open it (with its response), render its saved response, duplicate or delete it.
/// Opening over unsaved changes and deleting both ask first.
struct SavedRequestsPopover: View {
    /// A saved request waiting for the user to discard the draft's changes.
    private struct PendingOpen {
        var saved: SavedRequest
        var render: Bool
    }

    let client: ClientModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var pendingOpen: PendingOpen?
    @State private var pendingDelete: SavedRequest?

    private var library: SavedRequestLibrary { client.library }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query, prompt: Text("Name, method or URL"))
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            SavedRequestsList(requests: ClientPresentation.filter(library.requests, by: query), currentID: client.savedID,
                              isEmptyLibrary: library.requests.isEmpty, isLoaded: library.isLoaded,
                              open: { request(open: $0, render: false) }, render: { request(open: $0, render: true) },
                              duplicate: { saved in Task { _ = await library.duplicate(saved.id) } }, delete: { pendingDelete = $0 })
            Divider()
            SavedRequestsFooter(library: library)
        }
        .frame(width: 380, height: 440)
        .task { await library.loadIfNeeded() }
        .confirmationDialog("Discard the unsaved changes?", isPresented: Binding(get: { pendingOpen != nil }, set: { if !$0 { pendingOpen = nil } }),
                            presenting: pendingOpen) { pending in
            Button("Open “\(pending.saved.name)”", role: .destructive) { open(pending.saved, render: pending.render) }
        } message: { _ in
            Text("The request in the Client tab has changes that are not saved.")
        }
        .confirmationDialog("Delete the saved request?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { saved in
            Button("Delete “\(saved.name)”", role: .destructive) {
                Task {
                    if await library.delete(saved.id) { client.forget(saved.id) }
                }
            }
        } message: { _ in
            Text("Its request and saved response are removed from disk.")
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
}

private struct SavedRequestsList: View {
    let requests: [SavedRequest]
    let currentID: UUID?
    let isEmptyLibrary: Bool
    let isLoaded: Bool
    let open: (SavedRequest) -> Void
    let render: (SavedRequest) -> Void
    let duplicate: (SavedRequest) -> Void
    let delete: (SavedRequest) -> Void

    var body: some View {
        if !isLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if requests.isEmpty {
            ContentUnavailableView(isEmptyLibrary ? "No Saved Requests" : "No Matches", systemImage: "tray",
                                   description: Text(isEmptyLibrary ? "Save a request and its response with ⌘S." : "Try other words."))
        } else {
            List(requests) { saved in
                SavedRequestRow(saved: saved, isCurrent: saved.id == currentID)
                    .contentShape(Rectangle())
                    .onTapGesture { open(saved) }
                    .contextMenu {
                        Button("Open") { open(saved) }
                        Button("Render Saved Response") { render(saved) }
                            .disabled(saved.exchange?.response.carriesAResponseToRender != true)
                        Button("Duplicate") { duplicate(saved) }
                        Divider()
                        Button("Delete…", role: .destructive) { delete(saved) }
                    }
            }
            .listStyle(.plain)
        }
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

private struct SavedRequestsFooter: View {
    let library: SavedRequestLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            HStack(spacing: 10) {
                Text("\(library.requests.count) saved").foregroundStyle(.secondary)
                Spacer()
                Button("Import…") { SavedRequestTransfer.importArchive(into: library) }
                    .help("Import an export from another Mac: every request in it, merged by id (a newer copy wins)")
                Button("Export All…") { SavedRequestTransfer.exportAll(from: library) }
                    .disabled(library.requests.isEmpty)
                    .help("Write every saved request and its response to one file, to import on another Mac")
                Button("Show Folder") { showFolder() }
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
