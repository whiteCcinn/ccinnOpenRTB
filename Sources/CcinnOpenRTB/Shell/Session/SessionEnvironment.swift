import AppKit
import CcinnOpenRTBKit
import Foundation
import RTBKit

/// Monotonic seconds for the viewability timers; injectable so tests move time by hand.
protocol SessionClock: Sendable {
    func now() -> Double
}

struct SystemSessionClock: SessionClock {
    func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// Opens click-throughs in the default browser (Real mode with the setting on); injectable for tests.
@MainActor
protocol BrowserOpening: AnyObject {
    func open(_ url: URL)
}

@MainActor
final class WorkspaceBrowser: BrowserOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
