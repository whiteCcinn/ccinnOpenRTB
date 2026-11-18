import AppKit
import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// Scenes. Owner: app-shell (main window), kit-network (Network window, updates).
struct CcinnOpenRTBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("CcinnOpenRTB", id: "main") {
            MainWindowContent()
        }
        .defaultSize(width: 1500, height: 940)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands()
            UpdateCommands()
        }

        NetworkWindowScene()
        SettingsScene()
        SoftwareUpdateScene()
    }
}

/// The main window's content (its own view: one large scene expression is slow to type-check with Swift 6.2).
private struct MainWindowContent: View {
    private static let minimumWidth: CGFloat = 1100
    private static let minimumHeight: CGFloat = 720

    var body: some View {
        // Every argument given: `frame(minWidth:…)` with defaults is slow to resolve.
        MainView()
            .frame(minWidth: Self.minimumWidth, idealWidth: nil, maxWidth: nil, minHeight: Self.minimumHeight, idealHeight: nil, maxHeight: nil,
                   alignment: .center)
            .appAppearance()
            .presentsSoftwareUpdates()
            .networkLaunchSupport()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        UpdateController.shared.scheduleAutomaticCheck()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
