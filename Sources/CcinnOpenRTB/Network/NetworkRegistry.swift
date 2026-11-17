import CcinnOpenRTBKit
import Observation
import SwiftUI

/// Which session's monitor the (single) Network window shows: the most recently focused main window's.
///
/// App-shell wiring: attach `.providesNetworkMonitor(session.monitor)` to each main window's root view. The modifier
/// registers the monitor, makes it active whenever that window becomes key, applies Settings ▸ Network ▸ Request
/// timeout to it, and unregisters it when the window closes (the Network window then falls back to the next most
/// recently focused main window).
@MainActor
@Observable
final class NetworkRegistry {
    static let shared = NetworkRegistry()

    private(set) var activeMonitor: NetworkMonitor?
    /// Most recently activated first. Weak, so a closed window's monitor is never kept alive here.
    @ObservationIgnored private var recent: [WeakMonitor] = []

    init() {}

    func activate(_ monitor: NetworkMonitor) {
        recent.removeAll { $0.monitor == nil || $0.monitor === monitor }
        recent.insert(WeakMonitor(monitor: monitor), at: 0)
        if activeMonitor !== monitor { activeMonitor = monitor }
    }

    func unregister(_ monitor: NetworkMonitor) {
        recent.removeAll { $0.monitor == nil || $0.monitor === monitor }
        if activeMonitor === monitor { activeMonitor = recent.first?.monitor }
    }

    /// Registered monitors, most recent first (tests).
    var registered: [NetworkMonitor] { recent.compactMap(\.monitor) }

    private struct WeakMonitor {
        weak var monitor: NetworkMonitor?
    }
}

/// See `NetworkRegistry`.
struct NetworkMonitorProvider: ViewModifier {
    let monitor: NetworkMonitor
    var registry = NetworkRegistry.shared
    @Environment(\.controlActiveState) private var activeState
    @AppStorage(NetworkPreferences.requestTimeoutKey) private var timeout = NetworkPreferences.defaultRequestTimeout

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor.requestTimeout = timeout
                registry.activate(monitor)
            }
            .onChange(of: activeState) {
                if activeState == .key { registry.activate(monitor) }
            }
            .onChange(of: ObjectIdentifier(monitor)) { old, _ in
                // The session replaced its monitor: forget the old one, show the new one.
                if let previous = registry.registered.first(where: { ObjectIdentifier($0) == old }) { registry.unregister(previous) }
                monitor.requestTimeout = timeout
                registry.activate(monitor)
            }
            .onChange(of: timeout) {
                monitor.requestTimeout = timeout
            }
            .onDisappear {
                registry.unregister(monitor)
            }
    }
}

extension View {
    /// Makes `monitor` the one the Network window shows while this (main) window is focused. See `NetworkRegistry`.
    func providesNetworkMonitor(_ monitor: NetworkMonitor) -> some View {
        modifier(NetworkMonitorProvider(monitor: monitor))
    }
}
