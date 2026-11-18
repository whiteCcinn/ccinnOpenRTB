import RTBKit
import SwiftUI

/// The strip under the device: how much of the ad is in view, the MRC timers, and the manual lifecycle controls
/// (Render, Reset, Fire, Lose, Error).
struct SimulatorControls: View {
    @Bindable var session: AdSession

    /// Render needs a bid (or a response that may be a no-bid).
    private var canRender: Bool {
        let hasBid: Bool = session.selectedCandidate != nil
        return hasBid || session.parsed.kind.isBidResponse
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VisibilityControl(session: session)
                Spacer(minLength: 8)
                ViewabilityReadout(session: session)
            }
            HStack(spacing: 8) {
                Button {
                    session.render()
                } label: {
                    Label("Render", systemImage: "play.fill")
                }
                .help("Render the selected bid from scratch (⌘R)")
                .disabled(!canRender)
                Button {
                    session.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .help("Remove the ad and stop its timers (⌘⇧R)")
                .disabled(session.phase == .idle)
                Divider().frame(height: 18)
                FireMenu(session: session)
                LoseMenu(session: session)
                ErrorMenu(session: session)
                Spacer(minLength: 8)
                PhaseBadge(phase: session.phase, rendered: session.hasFired(.rendered), stale: session.renderIsStale)
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Visibility

/// "In view": the viewability slider (in-feed: it scrolls the feed; elsewhere a sheet covers part of the ad).
private struct VisibilityControl: View {
    let session: AdSession

    var body: some View {
        let fraction = session.visibleFraction
        HStack(spacing: 8) {
            Image(systemName: fraction >= 0.5 ? "eye" : "eye.slash")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("In view").foregroundStyle(.secondary)
            Slider(value: Binding(get: { session.visibleFraction }, set: { session.setVisibleFraction($0) }), in: 0...1)
                .frame(minWidth: 120, maxWidth: 220)
                .accessibilityLabel("Fraction of the ad in view")
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
        .font(.callout)
        .help(session.placement == .inFeed
            ? "Scrolls the feed: the ad's visible share drives the MRC timers (you can also scroll over the device)"
            : "Covers part of the ad: its visible share drives the MRC timers")
    }
}

/// MRC timer chips: display / Native 50% and 100% for 1 s, video 50% for 2 s of playback.
private struct ViewabilityReadout: View {
    let session: AdSession

    var body: some View {
        if session.phase == .ready, let prepared = session.prepared {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                HStack(spacing: 6) {
                    ForEach(chips(for: prepared), id: \.title) { chip in
                        TimerChip(title: chip.title, progress: chip.progress, fired: chip.fired)
                    }
                }
            }
        }
    }

    private struct Chip {
        var title: String
        var progress: Double
        var fired: Bool
    }

    private func chips(for prepared: PreparedAd) -> [Chip] {
        switch AdSession.viewabilityKind(markup: prepared.candidate.markup, format: prepared.candidate.format) {
        case .display:
            return [chip("MRC 50", .mrc50), chip("MRC 100", .mrc100)]
        case .native:
            return [chip("MRC 50", .mrc50), chip("MRC 100", .mrc100), chip("Video 50", .video50)]
        case .video:
            let count = max(1, prepared.vast?.ads.count ?? 1)
            return (0..<count).map { index in
                let fired = session.hasFired(.videoViewability(.viewable, adIndex: index))
                return Chip(title: count > 1 ? "Ad \(index + 1) viewable" : "Video viewable", progress: fired ? 1 : 0, fired: fired)
            }
        case .audio, .none:
            return []
        }
    }

    private func chip(_ title: String, _ level: ViewabilityLevel) -> Chip {
        let fired = session.hasFired(.viewable(level))
        return Chip(title: title, progress: fired ? 1 : session.viewabilityProgress(of: level), fired: fired)
    }
}

private struct TimerChip: View {
    let title: String
    let progress: Double
    let fired: Bool

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(fired ? Color.green : Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if fired {
                    Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.green)
                }
            }
            .frame(width: 13, height: 13)
            Text(title)
                .font(.caption)
                .foregroundStyle(fired ? .primary : .secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityValue(fired ? "fired" : "\(Int((progress * 100).rounded())) percent")
    }
}

// MARK: - Manual lifecycle

private struct FireMenu: View {
    let session: AdSession

    var body: some View {
        let sections = session.phase == .ready ? FireActions.sections(for: session.prepared) : []
        Menu {
            ForEach(sections) { section in
                if let title = section.title {
                    Section(title) { actions(section) }
                } else {
                    actions(section)
                }
            }
        } label: {
            Label("Fire", systemImage: "bolt.fill")
        }
        .fixedSize()
        .disabled(sections.isEmpty)
        .help("Fire a lifecycle event by hand (each fire-once event fires at most once per render)")
    }

    @ViewBuilder private func actions(_ section: FireSection) -> some View {
        ForEach(section.actions) { action in
            Button {
                session.fireManually(action.event)
            } label: {
                Label(action.title, systemImage: Self.symbol(for: action.kind))
            }
            .disabled(LifecycleGate.onceKey(for: action.event) != nil && session.hasFired(action.event))
        }
    }

    private static func symbol(for kind: FireAction.Kind) -> String {
        switch kind {
        case .impression: "eye"
        case .viewability: "eye.circle"
        case .click: "cursorarrow.click"
        case .close: "xmark.circle"
        }
    }
}

private struct LoseMenu: View {
    let session: AdSession

    var body: some View {
        Menu {
            ForEach(LossReason.lossReasons) { reason in
                Button("\(reason.code) · \(reason.title)") { session.lose(reason) }
            }
        } label: {
            Label("Lose", systemImage: "flag.slash")
        }
        .fixedSize()
        .disabled(session.selectedCandidate == nil)
        .help("The bid lost the auction: send the loss notice (lurl) with this reason instead of rendering")
    }
}

private struct ErrorMenu: View {
    let session: AdSession

    var body: some View {
        let targets = errorTargets
        Menu {
            ForEach(targets, id: \.title) { target in
                Menu(target.title) {
                    ForEach(Self.groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.codes, id: \.self) { code in
                                Button("\(code.rawValue) · \(code.title)") { session.fireManually(.error(code, adIndex: target.adIndex)) }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Error", systemImage: "exclamationmark.triangle")
        }
        .fixedSize()
        .disabled(targets.isEmpty)
        .help("Fire VAST Error trackers with [ERRORCODE]")
    }

    private struct Target {
        var title: String
        var adIndex: Int?
    }

    private var errorTargets: [Target] {
        guard session.phase == .ready, session.isVAST else { return [] }
        let count = session.prepared?.vast?.ads.count ?? 0
        return [Target(title: "Whole chain", adIndex: nil)] + (0..<count).map { Target(title: "Ad \($0 + 1)", adIndex: $0) }
    }

    private struct Group {
        var title: String
        var codes: [VASTErrorCode]
    }

    private static let groups: [Group] = [
        Group(title: "XML", codes: VASTErrorCode.allCases.filter { $0.rawValue < 200 }),
        Group(title: "Trafficking", codes: VASTErrorCode.allCases.filter { (200..<300).contains($0.rawValue) }),
        Group(title: "Wrapper", codes: VASTErrorCode.allCases.filter { (300..<400).contains($0.rawValue) }),
        Group(title: "Linear", codes: VASTErrorCode.allCases.filter { (400..<500).contains($0.rawValue) }),
        Group(title: "Other", codes: VASTErrorCode.allCases.filter { $0.rawValue >= 500 }),
    ]
}

/// Where the render is, at a glance. "Rendered" means the ad rendered (`.rendered`, the billing moment), not only that it
/// is on the device.
struct PhaseBadge: View {
    let phase: RenderPhase
    /// The renderer reported `.rendered`.
    var rendered = false
    var stale = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(stale ? "On the device · selection changed" : title).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(stale ? "The selected bid differs from the one on the device: Render to update" : title)
    }

    private var title: String { Self.title(for: phase, rendered: rendered) }

    nonisolated static func title(for phase: RenderPhase, rendered: Bool) -> String {
        switch phase {
        case .idle: "Idle"
        case let .preparing(message): message
        case .ready: rendered ? "Rendered" : "On the device · not rendered"
        case let .noBid(reason): reason.map { "No bid (nbr \($0))" } ?? "No bid"
        case .needsRealMode: "Needs Real mode"
        case .failed: "Failed"
        case let .lost(reason): "Lost (\(reason.code))"
        }
    }

    private var color: Color {
        if stale { return .orange }
        switch phase {
        case .idle: return .secondary
        case .preparing: return .yellow
        case .ready: return rendered ? .green : .yellow
        case .noBid, .lost: return .gray
        case .needsRealMode: return .orange
        case .failed: return .red
        }
    }
}

extension InputKind {
    /// An OpenRTB bid response (rendering one without bids shows "No bid").
    var isBidResponse: Bool {
        if case .bidResponse = self { return true }
        return false
    }
}
