import Foundation

/// The `origin` of a renderer console line (`RendererLogEntry.origin`).
enum RendererLogOrigin: String, Sendable, CaseIterable {
    /// MRAID bridge calls and `error` events.
    case mraid = "MRAID"
    case vast = "VAST"
    case native = "Native"
    /// The HTML creative: its web view, its navigations and its own `console.*` output.
    case html = "HTML"
    /// The OpenRTB 3.0 image banner.
    case display = "Display"
}

extension RendererLogEntry {
    init(_ origin: RendererLogOrigin, _ level: Level = .info, _ message: String, date: Date = Date()) {
        self.init(date: date, origin: origin.rawValue, level: level, message: message)
    }
}
