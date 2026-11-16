import AppKit
import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// Scenes. Owner: app-shell (main window), kit-network (Network window, updates).
struct CcinnOpenRTBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("CcinnOpenRTB", id: "main") {
            MainView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1500, height: 940)
        .windowToolbarStyle(.unified(showsTitle: false))
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
