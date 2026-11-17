import CcinnOpenRTBKit
import SwiftUI

/// The Network window (Window ▸ Network, ⌥⌘N). It shows the focused main window's monitor (`NetworkRegistry`).
struct NetworkWindowScene: Scene {
    static let windowID = "network"

    var body: some Scene {
        Window("Network", id: Self.windowID) {
            NetworkWindowView()
                .appAppearance()
        }
        .defaultSize(width: 1320, height: 680)
        .keyboardShortcut("n", modifiers: [.command, .option])
    }
}

/// Toolbar button that opens (or brings forward) the Network window; app-shell can place it in the main toolbar.
struct NetworkWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var registry = NetworkRegistry.shared

    var body: some View {
        Button {
            openWindow(id: NetworkWindowScene.windowID)
        } label: {
            Label("Network", systemImage: "antenna.radiowaves.left.and.right")
        }
        .help("Show the Network window (⌥⌘N)")
    }
}

extension OpenWindowAction {
    /// Opens the Network window.
    @MainActor
    func openNetworkWindow() {
        callAsFunction(id: NetworkWindowScene.windowID)
    }
}
