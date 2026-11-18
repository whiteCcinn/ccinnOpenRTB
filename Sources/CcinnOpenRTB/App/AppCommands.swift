import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// The Simulator menu: render, reset, rotate, zoom and the tracking mode of the focused main window.
struct AppCommands: Commands {
    @FocusedValue(\.adSession) private var session

    var body: some Commands {
        // Split into sections: one large builder expression is slow to type-check (CI builds with Swift 6.2).
        CommandMenu("Simulator") {
            SimulatorRenderSection(session: session)
            Divider()
            SimulatorViewSection(session: session, zoom: zoom)
            Divider()
            SimulatorModeSection(session: session)
        }
    }

    private func zoom(_ step: (Double) -> ZoomSetting) {
        guard let session else { return }
        session.zoom = step(session.canvasMagnification)
    }
}

private struct SimulatorRenderSection: View {
    let session: AdSession?

    var body: some View {
        Button("Render") { session?.render() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(session == nil)
        Button("Reset") { session?.reset() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(session == nil || session?.phase == .idle)
    }
}

private struct SimulatorViewSection: View {
    let session: AdSession?
    let zoom: (_ step: (Double) -> ZoomSetting) -> Void

    var body: some View {
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
    }
}

private struct SimulatorModeSection: View {
    let session: AdSession?

    private var selection: Binding<SessionMode> {
        Binding(get: { session?.sessionMode ?? .simulated }, set: { session?.choose($0) })
    }

    var body: some View {
        Picker("Network Mode", selection: selection) {
            ForEach(SessionMode.allCases) { mode in
                Text(mode == .real ? mode.title + "…" : mode.title).tag(mode)
            }
        }
        .pickerStyle(.inline)
        .disabled(session == nil)
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
