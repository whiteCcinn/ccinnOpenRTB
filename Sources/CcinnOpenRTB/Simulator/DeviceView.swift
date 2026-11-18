import RTBKit
import SwiftUI

/// The simulated device: physical frame, screens with the mock app and the ad, system chrome, hinge or crease.
/// Drawn at 1 pt = 1 device point; the canvas around it zooms.
struct DeviceView: View {
    let session: AdSession

    var body: some View {
        let layout = session.layout
        let style = DeviceFrameStyle(layout: layout)
        ZStack(alignment: .topLeading) {
            DeviceBodyView(style: style, layout: layout)
            ScreensView(session: session, layout: layout, style: style)
                .frame(width: layout.canvasSize.width, height: layout.canvasSize.height, alignment: .topLeading)
                .offset(x: style.canvasOrigin.x, y: style.canvasOrigin.y)
        }
        .frame(width: style.outerSize.width, height: style.outerSize.height, alignment: .topLeading)
    }
}

/// Body, bezel, buttons, home button, TV stand.
private struct DeviceBodyView: View {
    let style: DeviceFrameStyle
    let layout: ScreenLayout

    private var band: LinearGradient {
        LinearGradient(colors: [Color(white: 0.62), Color(white: 0.30), Color(white: 0.52)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let neck = style.standNeck, let base = style.standBase {
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.38), Color(white: 0.22)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: neck.width, height: neck.height)
                    .offset(x: neck.minX, y: neck.minY)
                RoundedRectangle(cornerRadius: base.height / 2, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
                    .frame(width: base.width, height: base.height)
                    .offset(x: base.minX, y: base.minY)
            }
            ForEach(Array(style.buttons.enumerated()), id: \.offset) { _, button in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(band)
                    .frame(width: button.frame.width, height: button.frame.height)
                    .offset(x: button.frame.minX, y: button.frame.minY)
            }
            ForEach(Array(slabs.enumerated()), id: \.offset) { _, slab in
                RoundedRectangle(cornerRadius: slab.radius, style: .continuous)
                    .fill(Color(white: 0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: slab.radius, style: .continuous)
                            .strokeBorder(band, lineWidth: style.body == .television ? 4 : 3)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: max(0, slab.radius - 3), style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                            .padding(3)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
                    .frame(width: slab.frame.width, height: slab.frame.height)
                    .offset(x: slab.frame.minX, y: slab.frame.minY)
            }
            if let hinge = hingeFrame {
                RoundedRectangle(cornerRadius: min(hinge.width, hinge.height) / 2, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.7), Color(white: 0.3)],
                                         startPoint: layout.isLandscape ? .top : .leading, endPoint: layout.isLandscape ? .bottom : .trailing))
                    .frame(width: hinge.width, height: hinge.height)
                    .offset(x: hinge.minX, y: hinge.minY)
            }
            if let home = style.homeButton {
                Circle()
                    .fill(Color(white: 0.08))
                    .overlay(Circle().strokeBorder(band, lineWidth: 2.5))
                    .frame(width: home.width, height: home.height)
                    .offset(x: home.minX, y: home.minY)
            }
            if let earpiece = style.earpiece {
                Capsule().fill(Color(white: 0.2))
                    .frame(width: earpiece.width, height: earpiece.height)
                    .offset(x: earpiece.minX, y: earpiece.minY)
            }
            if let camera = style.frontCamera {
                Circle().fill(Color(red: 0.10, green: 0.12, blue: 0.20))
                    .overlay(Circle().fill(Color(red: 0.3, green: 0.4, blue: 0.7).opacity(0.5)).padding(camera.width * 0.3))
                    .frame(width: camera.width, height: camera.height)
                    .offset(x: camera.minX, y: camera.minY)
            }
            if style.body == .television {
                Capsule().fill(Color.white.opacity(0.35))
                    .frame(width: 60, height: 5)
                    .offset(x: style.bodyFrame.midX - 30, y: style.bodyFrame.maxY - 16)
            }
        }
        .frame(width: style.outerSize.width, height: style.outerSize.height, alignment: .topLeading)
    }

    private struct Slab {
        var frame: CGRect
        var radius: CGFloat
    }

    /// One body, or for dual-screen devices one slab per screen joined by the hinge.
    private var slabs: [Slab] {
        guard layout.hinge != nil, layout.panes.count == 2 else {
            return [Slab(frame: style.bodyFrame, radius: style.bodyCornerRadius)]
        }
        let origin = style.canvasOrigin
        let inner: CGFloat = 6
        let radius = max(14, layout.cornerRadius + 10)
        return layout.panes.enumerated().map { index, pane in
            let screen = pane.frame.offsetBy(dx: origin.x, dy: origin.y)
            var frame = style.bodyFrame
            if layout.isLandscape {
                frame = index == 0 ? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: screen.maxY + inner - frame.minY)
                    : CGRect(x: frame.minX, y: screen.minY - inner, width: frame.width, height: frame.maxY - screen.minY + inner)
            } else {
                frame = index == 0 ? CGRect(x: frame.minX, y: frame.minY, width: screen.maxX + inner - frame.minX, height: frame.height)
                    : CGRect(x: screen.minX - inner, y: frame.minY, width: frame.maxX - screen.minX + inner, height: frame.height)
            }
            return Slab(frame: frame, radius: radius)
        }
    }

    /// The hinge between the two slabs (dual-screen).
    private var hingeFrame: CGRect? {
        guard let hinge = layout.hinge else { return nil }
        let origin = style.canvasOrigin
        let gap = hinge.offsetBy(dx: origin.x, dy: origin.y)
        if layout.isLandscape {
            return CGRect(x: gap.minX + 30, y: gap.minY + 6, width: gap.width - 60, height: max(4, gap.height - 12))
        }
        return CGRect(x: gap.minX + 6, y: gap.minY + 30, width: max(4, gap.width - 12), height: gap.height - 60)
    }
}

/// The screens: the app in `contentFrame` (both screens when spanned), the companion pane, chrome, crease.
private struct ScreensView: View {
    let session: AdSession
    let layout: ScreenLayout
    let style: DeviceFrameStyle

    var body: some View {
        let content = layout.contentFrame
        let fullScreenAd = session.placement.isFullScreen && session.renderRequest != nil
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.panes.enumerated()), id: \.offset) { _, pane in
                RoundedRectangle(cornerRadius: style.screenCornerRadius, style: .continuous)
                    .fill(.black)
                    .frame(width: pane.frame.width, height: pane.frame.height)
                    .offset(x: pane.frame.minX, y: pane.frame.minY)
            }
            if !layout.isSpanned, layout.panes.count == 2, let second = layout.panes.last {
                StoryListPane(layout: layout, size: second.frame.size)
                    .offset(x: second.frame.minX, y: second.frame.minY)
            }
            SimulatedAppView(session: session, layout: layout)
                .frame(width: content.width, height: content.height)
                .offset(x: content.minX, y: content.minY)
            if let hinge = layout.hinge {
                Rectangle().fill(Color(white: 0.04))
                    .frame(width: hinge.width, height: hinge.height)
                    .offset(x: hinge.minX, y: hinge.minY)
            }
            ForEach(Array(layout.panes.enumerated()), id: \.offset) { index, pane in
                let inContent = content.intersects(pane.frame.insetBy(dx: 1, dy: 1))
                SystemChrome(layout: layout, pane: pane.frame, showsStatusBar: !(fullScreenAd && inContent), isFirstPane: index == 0,
                             lightContent: fullScreenAd && inContent)
                    .offset(x: pane.frame.minX, y: pane.frame.minY)
            }
            if let crease = layout.crease { CreaseView(crease: crease, size: layout.canvasSize) }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height, alignment: .topLeading)
        .mask {
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.panes.enumerated()), id: \.offset) { _, pane in
                    RoundedRectangle(cornerRadius: style.screenCornerRadius, style: .continuous)
                        .frame(width: pane.frame.width, height: pane.frame.height)
                        .offset(x: pane.frame.minX, y: pane.frame.minY)
                }
                if let hinge = layout.hinge {
                    Rectangle().frame(width: hinge.width, height: hinge.height).offset(x: hinge.minX, y: hinge.minY).opacity(0)
                }
            }
            .frame(width: layout.canvasSize.width, height: layout.canvasSize.height, alignment: .topLeading)
        }
    }
}

/// The fold of an unfolded foldable: a soft shadowed line.
private struct CreaseView: View {
    let crease: ScreenLayout.Crease
    let size: CGSize

    var body: some View {
        switch crease {
        case let .vertical(x):
            LinearGradient(colors: [.clear, .black.opacity(0.16), .white.opacity(0.10), .black.opacity(0.16), .clear], startPoint: .leading,
                           endPoint: .trailing)
                .frame(width: 14, height: size.height)
                .offset(x: x - 7)
                .allowsHitTesting(false)
        case let .horizontal(y):
            LinearGradient(colors: [.clear, .black.opacity(0.16), .white.opacity(0.10), .black.opacity(0.16), .clear], startPoint: .top,
                           endPoint: .bottom)
                .frame(width: size.width, height: 14)
                .offset(y: y - 7)
                .allowsHitTesting(false)
        }
    }
}

/// The publisher app for the current placement, with the ad (or its empty slot) in place.
struct SimulatedAppView: View {
    let session: AdSession
    let layout: ScreenLayout

    var body: some View {
        let size = layout.contentFrame.size
        let adSize = session.adSize
        switch session.placement {
        case .inlineBanner:
            NewsArticleApp(layout: layout, size: size, banner: session.bannerPosition, bannerHeight: adSize.height,
                           visibleFraction: session.visibleFraction) {
                AdSlotView(session: session, size: adSize)
            }
        case .inFeed:
            FeedApp(layout: layout, size: size, geometry: session.feedGeometry, offset: session.feedOffset,
                    captioned: session.slotCandidate?.format != .native) {
                AdSlotView(session: session, size: adSize)
            }
            .overlay { FeedScrollCapture(session: session) }
        case .interstitial, .rewarded:
            FullScreenPlacement(session: session, layout: layout, television: false) {
                NewsArticleApp(layout: layout, size: size, banner: nil, bannerHeight: 0, visibleFraction: 1) { EmptyView() }
            }
        case .ctvInstream:
            FullScreenPlacement(session: session, layout: layout, television: true) {
                TVHomeApp(size: size)
            }
        }
    }
}

/// A full-screen placement: the app behind, the ad's black backdrop (the dimmed app while there is no ad), and the slot —
/// ad or placeholder — at `AdSizing.slotFrame`, the safe-area rect whose size the ad reports.
///
/// The shell draws no close control here: the renderer owns the full-screen chrome (the interstitial close after its delay,
/// the rewarded countdown, VAST skip and close, MRAID custom close, Back on CTV) because only it knows the playback state,
/// `skipoffset` and the creative's close state. Its top-right control lands inside the safe area because the slot is the
/// safe-area rect. The Fire menu's Close is the manual equivalent.
private struct FullScreenPlacement<Background: View>: View {
    let session: AdSession
    let layout: ScreenLayout
    let television: Bool
    @ViewBuilder let background: () -> Background

    var body: some View {
        let size = layout.contentFrame.size
        let slot = AdSizing.slotFrame(placement: session.placement, adSize: session.adSize, layout: layout)
        ZStack(alignment: .topLeading) {
            background()
            if session.renderRequest != nil {
                Color.black
                AdSlotView(session: session, size: slot.size)
                    .frame(width: slot.width, height: slot.height)
                    .offset(x: slot.minX, y: slot.minY)
            } else {
                Color.black.opacity(television ? 0.45 : 0.35)
                // Legible on the dimmed app, and never under a hinge.
                AdSlotView(session: session, size: slot.size, labelArea: AdSizing.placeholderLabelRect(slot: slot, layout: layout))
                    .frame(width: slot.width, height: slot.height)
                    .offset(x: slot.minX, y: slot.minY)
                    .environment(\.colorScheme, .dark)
            }
            OcclusionSheet(size: size, visibleFraction: session.visibleFraction, television: television)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
