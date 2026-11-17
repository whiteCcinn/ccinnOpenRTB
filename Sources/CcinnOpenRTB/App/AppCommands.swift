import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// The Simulator menu: render, reset, rotate, zoom and the tracking mode of the focused main window.
struct AppCommands: Commands {
    @FocusedValue(\.adSession) private var session

    var body: some Commands {
        CommandMenu("Simulator") {
            Button("Render") { session?.render() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session == nil)
            Button("Reset") { session?.reset() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session == nil || session?.phase == .idle)
            Divider()
            Button("Rotate") { session?.landscape.toggle() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(session == nil || session?.device.family == .ctv)
            Divider()
            Button("Zoom In") { zoom { ZoomSetting.zoomedIn(from: $0) } }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(session == nil)
            Button("Zoom Out") { zoom { ZoomSetting.zoomedOut(from: $0) } }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(session == nil)
            Button("Zoom to Fit") { session?.zoom = .fit }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(session == nil)
            Divider()
            if session?.mode == .real {
                Button("Switch to Simulated Mode") { session?.useSimulatedMode() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            } else {
                Button("Switch to Real Mode…") { session?.requestRealMode() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(session == nil)
            }
        }
    }

    private func zoom(_ step: (Double) -> ZoomSetting) {
        guard let session else { return }
        session.zoom = step(session.canvasMagnification)
    }
}
