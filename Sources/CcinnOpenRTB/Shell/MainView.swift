import AppKit
import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// Main window: simulator on the left, response editor and inspector on the right. Owner: app-shell. Each window has its
/// own session (and so its own network monitor and tracking mode).
struct MainView: View {
    @State private var session = AdSession()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            SimulatorPane(session: session)
                .frame(minWidth: 520, idealWidth: 880, maxWidth: .infinity, maxHeight: .infinity)
            InputPanel(session: session)
                .frame(minWidth: 420, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { MainToolbar(session: session) }
        // isPresented, not item: the confirmation's host list completes after the markup is inspected, and an item that
        // changes would dismiss the sheet (and its dismissal would cancel the request).
        .sheet(isPresented: Binding(get: { session.realModeConfirmation != nil }, set: { if !$0 { session.cancelRealMode() } })) {
            RealModeSheetHost(session: session)
        }
        .navigationTitle("CcinnOpenRTB")
        .providesNetworkMonitor(session.monitor)
        .focusedSceneValue(\.adSession, session)
        .task { await LaunchCoordinator.run(session: session, openNetworkWindow: { openWindow(id: NetworkWindowScene.windowID) }) }
    }
}

extension FocusedValues {
    /// The session of the focused main window (menu commands).
    @Entry var adSession: AdSession?
}

/// Applies the launch arguments to the first main window, opens the Network window and takes the snapshot.
@MainActor
enum LaunchCoordinator {
    private static var didRun = false

    static func run(session: AdSession, openNetworkWindow: () -> Void, options: LaunchOptions = LaunchOptions()) async {
        guard !didRun, !options.isEmpty else { return }
        didRun = true
        await options.apply(to: session, samples: session.services.samples())
        if options.opensNetworkWindow { openNetworkWindow() }
        guard let path = options.snapshotPath else { return }
        try? await Task.sleep(for: .seconds(options.snapshotDelay))
        SnapshotTool.captureMainWindow(to: URL(fileURLWithPath: path))
        if options.quitAfterSnapshot { NSApp.terminate(nil) }
    }
}

/// `--snapshot <file.png>`: renders the main window (with its toolbar) into a PNG without screen-recording permission.
/// Layer-hosted content (a creative's web view, video) is drawn as AppKit caches it, which can be blank.
@MainActor
enum SnapshotTool {
    static func captureMainWindow(to url: URL) {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true } + [NSApp.keyWindow].compactMap { $0 }
        guard let window = candidates.first(where: { $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
