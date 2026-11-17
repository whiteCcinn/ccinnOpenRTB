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

/// Bridges to `VASTTrackingPlan.resolutionRequests(vast:context:source:)` (kit-vast). Until that lands on main the
/// placeholder plan has no resolution requests, so this returns none.
enum VASTResolutionPlan {
    static func requests(vast: ResolvedVAST, context: MacroContext, source: String) -> [TrackerRequest] {
        []
    }
}
