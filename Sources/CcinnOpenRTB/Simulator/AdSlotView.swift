import RTBKit
import SwiftUI

/// The ad (through the renderers' `AdView`) or, while there is none, an outlined slot saying why. Both are drawn at
/// `size`, and the placeholder's label is that size: what the slot says is what it is.
///
/// The simulator's own text in the slot (the placeholder's label, a renderer's message) goes to the slot's part on one
/// screen when a dual-screen hinge crosses it, and is sized for the 10-foot UI on a CTV (`SimulatorTextLayout`).
struct AdSlotView: View {
    let session: AdSession
    let size: CGSize
    /// Where the placeholder's label goes inside the slot; `nil`: found from where the slot is on the screen.
    var labelArea: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let area = labelArea ?? AdSizing.placeholderLabelRect(slot: proxy.frame(in: .named(SimulatorTextLayout.screenSpace)),
                                                                  layout: session.layout)
            slot(textArea: area)
                .environment(\.simulatorTextArea, area)
                .environment(\.simulatorTextScale, SimulatorTextLayout.scale(device: session.device, slot: size))
                .coordinateSpace(name: SimulatorTextLayout.adSpace)
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder private func slot(textArea: CGRect) -> some View {
        if let request = session.renderRequest {
            AdView(request: request, host: session.rendererHost)
                .frame(width: size.width, height: size.height)
                .clipped()
                .id(request.generation)
        } else {
            AdSlotPlaceholder(phase: session.phase, format: session.slotCandidate?.format, size: size, compact: size.height < 90,
                              labelArea: textArea)
                .frame(width: size.width, height: size.height)
        }
    }
}

struct AdSlotPlaceholder: View {
    let phase: RenderPhase
    let format: AdFormat?
    /// The size the slot is drawn at (its label).
    let size: CGSize
    let compact: Bool
    /// The part of the slot the label is centred in (`nil`: the whole slot).
    var labelArea: CGRect?

    var body: some View {
        let area = labelArea ?? CGRect(origin: .zero, size: size)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.07))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            content
                .padding(compact ? 4 : 12)
                .frame(width: max(0, area.width), height: max(0, area.height))
                .offset(x: area.minX, y: area.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        if compact {
            HStack(spacing: 6) {
                icon.font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .foregroundStyle(tint)
        } else {
            let scale = Self.textScale(for: size)
            VStack(spacing: 6 * scale) {
                icon.font(.system(size: 22 * scale, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 13 * scale, weight: .semibold)).multilineTextAlignment(.center)
                if let detail {
                    Text(detail).font(.system(size: 11 * scale)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Type size relative to the phone size: 1 up to a 360 pt short side, growing with larger slots up to 3 (a 1080 pt
    /// TV slot), so the label stays legible however the canvas is zoomed to fit.
    nonisolated static func textScale(for size: CGSize) -> CGFloat {
        let shortSide = min(size.width, size.height)
        guard shortSide.isFinite, shortSide > 0 else { return 1 }
        return min(3, max(1, shortSide / 360))
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .preparing: ProgressView().controlSize(.small)
        default: Image(systemName: symbol)
        }
    }

    /// `W × H` in whole points.
    static func sizeText(_ size: CGSize) -> String {
        func points(_ value: CGFloat) -> Int { value.isFinite ? Int(max(0, min(value, 100_000)).rounded()) : 0 }
        return "\(points(size.width)) × \(points(size.height))"
    }

    private var title: String {
        switch phase {
        case .idle: "Ad slot · \(Self.sizeText(size))"
        case let .preparing(message): message
        case .ready: "Ad"
        case let .noBid(reason): reason.map { "No bid · nbr \($0)" } ?? "No bid"
        case .needsRealMode: "Markup comes from the win notice"
        case .failed: "Could not render"
        case let .lost(reason): "Lost · \(reason.code)"
        }
    }

    private var detail: String? {
        switch phase {
        case .idle: compact ? "Render ⌘R" : "Paste a response and Render (⌘R)"
        case .preparing: nil
        case .ready: nil
        case let .noBid(reason): reason.map(NoBidReason.title(for:))
        case let .needsRealMode(message): message
        case let .failed(message): message
        case let .lost(reason): reason.title
        }
    }

    private var symbol: String {
        switch phase {
        case .idle:
            switch format {
            case .video?: "play.rectangle"
            case .audio?: "waveform"
            case .native?: "rectangle.grid.1x2"
            default: "rectangle.dashed"
            }
        case .preparing, .ready: "rectangle"
        case .noBid: "nosign"
        case .needsRealMode: "lock.shield"
        case .failed: "exclamationmark.triangle"
        case .lost: "flag.slash"
        }
    }

    private var tint: Color {
        switch phase {
        case .failed: .red
        case .needsRealMode, .lost: .orange
        case .noBid: .secondary
        default: Theme.accent
        }
    }
}

/// OpenRTB no-bid reason codes (OpenRTB 2.5 §5.24).
enum NoBidReason {
    static func title(for code: Int) -> String {
        switch code {
        case 0: "Unknown error"
        case 1: "Technical error"
        case 2: "Invalid request"
        case 3: "Known web spider"
        case 4: "Suspected non-human traffic"
        case 5: "Cloud, data center or proxy IP"
        case 6: "Unsupported device"
        case 7: "Blocked publisher or site"
        case 8: "Unmatched user"
        case 9: "Daily reader cap met"
        case 10: "Daily domain cap met"
        default: "Exchange-specific reason"
        }
    }
}
