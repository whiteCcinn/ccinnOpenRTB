import Foundation
import RTBKit

/// Where the current render is.
enum RenderPhase: Equatable, Sendable {
    /// Nothing rendered yet (or reset).
    case idle
    /// Fetching markup or resolving VAST.
    case preparing(String)
    /// The ad is on the device.
    case ready
    /// The response is a no-bid (`nbr`), or has no bids.
    case noBid(reason: Int?)
    /// The markup is delivered by the win notice and Simulated mode does not send it.
    case needsRealMode(String)
    case failed(String)
    /// The bid lost the auction (Lose control); the loss notice was sent.
    case lost(LossReason)
}

/// A bid prepared for rendering: markup fetched, Native parsed, VAST resolved.
struct PreparedAd: Equatable, Sendable {
    /// The bid with `markup` replaced by fetched markup when it came from `markupURL` / the win notice.
    var candidate: AdCandidate
    var native: NativeAd?
    var vast: ResolvedVAST?
    /// The network entry that delivered the markup (win notice or display.curl), parent of later requests.
    var markupEntryID: UUID?
    /// The win notice delivered the markup, so it was already sent (or recorded) and `.won` does not send it again.
    var markupFromWinNotice: Bool
    /// The markup as the device receives it, when the exchange changed it: inline `adm` (HTML, Native JSON, VAST XML) with
    /// the OpenRTB `${…}` macros substituted (OpenRTB 2.6 §4.4); `native` and `vast` are parsed from it. `nil`:
    /// `candidate.markup` as is. `candidate` keeps the bid's own markup.
    var deviceMarkup: AdMarkup? = nil
}

/// One line of the session's lifecycle log (simulator panel).
struct LifecycleLogEntry: Identifiable, Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Fired; `requests` tracker requests were dispatched.
        case fired(requests: Int)
        case alreadyFired
        case contradictsOutcome
        case ignored(String)
    }

    let id: Int
    let time: Date
    let label: String
    let origin: String
    let outcome: Outcome
}

extension AdLifecycleEvent {
    /// Short label for the lifecycle log and the Fire menu.
    var label: String {
        switch self {
        case .won: "win"
        case .rendered: "rendered (billing, impressions)"
        case let .viewable(level): "viewable \(level.rawValue)"
        case let .videoViewability(outcome, adIndex): "VAST \(outcome.rawValue) · ad \(adIndex + 1)"
        case let .video(event, adIndex): "VAST \(event.label) · ad \(adIndex + 1)"
        case let .companionView(adIndex, companionIndex): "companion \(companionIndex + 1) view · ad \(adIndex + 1)"
        case let .companionClick(adIndex, companionIndex): "companion \(companionIndex + 1) click · ad \(adIndex + 1)"
        case let .iconView(adIndex, iconIndex): "icon \(iconIndex &+ 1) view · ad \(adIndex &+ 1)"
        case let .iconClick(adIndex, iconIndex): "icon \(iconIndex &+ 1) click · ad \(adIndex &+ 1)"
        case let .click(assetID): assetID.map { "click · asset \($0)" } ?? "click"
        case let .videoClick(adIndex): "VAST click · ad \(adIndex + 1)"
        case .closed: "close"
        case let .loss(reason): "loss (\(reason))"
        case let .error(code, adIndex): "error \(code.rawValue)" + (adIndex.map { " · ad \($0 + 1)" } ?? "")
        }
    }
}

extension VASTEvent {
    var label: String {
        switch self {
        case let .progress(offset):
            switch offset {
            case let .seconds(value): "progress \(value.formatted(.number.precision(.fractionLength(0...3)))) s"
            case let .percent(value): "progress \(value.formatted(.number.precision(.fractionLength(0...2))))%"
            }
        case let .other(name): name
        default: String(describing: self)
        }
    }
}
