import AppKit
import UniformTypeIdentifiers

/// Moving saved requests between Macs: Export All writes one archive (`SavedRequestArchive`) where the user chooses;
/// Import reads one and merges it into the library in one go. The outcome is in the library's `lastNotice` /
/// `lastError`.
@MainActor
enum SavedRequestTransfer {
    static func exportAll(from library: SavedRequestLibrary) {
        let panel = NSSavePanel()
        panel.title = "Export Saved Requests"
        panel.message = "The export holds every saved request with its last response, headers (credentials included) and the requests’ personal data. Keep it private."
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "CcinnOpenRTB Saved Requests \(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { try? await library.exportArchive(to: url) }
    }

    static func importArchive(into library: SavedRequestLibrary) {
        let panel = NSOpenPanel()
        panel.title = "Import Saved Requests"
        panel.message = "Choose a CcinnOpenRTB saved-requests export (or a saved request file). Requests are merged: a newer copy replaces an older one."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { try? await library.importArchive(contentsOf: url) }
    }
}
