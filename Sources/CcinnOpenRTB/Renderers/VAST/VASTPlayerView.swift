import RTBKit
import SwiftUI

/// What a VAST player is for.
enum VASTPlayerRole: Equatable, Sendable {
    /// The bid's own VAST (video or audio): reports `.rendered`, shows companions and the end card.
    case ad(audioOnly: Bool)
    /// A Native ad's video asset: the Native ad's impression is its own, no companions.
    case nativeVideo(assetID: Int)

    var audioOnly: Bool {
        if case let .ad(audioOnly) = self { audioOnly } else { false }
    }
}

extension VASTPlayerConfiguration {
    init(request: RenderRequest, role: VASTPlayerRole, playerSize: CGSize) {
        let source = switch role {
        case .ad: request.sourceRoot + " › VAST"
        case let .nativeVideo(assetID): request.sourceRoot + " › native › asset \(assetID) (video) › VAST"
        }
        self.init(placement: request.placement, device: request.device, playerSize: playerSize, audioOnly: role.audioOnly, source: source)
        if case .nativeVideo = role {
            reportsRendered = false
            showsCompanions = false
        }
    }
}

/// The VAST player: video (phone / tablet / foldable layouts, or the 10-foot CTV layout) or the audio card.
struct VASTPlayerView: View {
    let vast: ResolvedVAST
    let request: RenderRequest
    let host: any AdRenderingHost
    let role: VASTPlayerRole
    /// The player's own size when it is part of a layout (Native video); the whole ad area otherwise.
    var playerSize: CGSize?

    @State private var model: VASTPlayerModel?

    var body: some View {
        ZStack {
            if let model {
                VASTPlayerContent(model: model, request: request, host: host, role: role)
            } else {
                Color.black
            }
        }
        .task(id: request.generation) {
            let active = activeModel()
            active.setVisibleFraction(request.visibleFraction)
            active.start()
        }
        .onChange(of: request.visibleFraction) { _, fraction in model?.setVisibleFraction(fraction) }
        .onDisappear { model?.teardown() }
    }

    private func activeModel() -> VASTPlayerModel {
        if let model, !model.isTornDown { return model }
        let configuration = VASTPlayerConfiguration(request: request, role: role, playerSize: playerSize ?? request.adSize)
        let created = VASTPlayerModel(vast: vast, configuration: configuration, host: host, engine: AVPlaybackEngine())
        model = created
        return created
    }
}

private struct VASTPlayerContent: View {
    let model: VASTPlayerModel
    let request: RenderRequest
    let host: any AdRenderingHost
    let role: VASTPlayerRole

    var body: some View {
        if model.phase == .closed {
            RendererMessageView(symbol: "xmark.circle", title: "Ad closed", detail: "Render again (⌘R) to show it again.")
        } else if model.configuration.isCTV {
            CTVPlayerLayout(model: model)
        } else if role.audioOnly {
            AudioAdCard(model: model, request: request, host: host)
        } else {
            VideoPlayerLayout(model: model, request: request, host: host, role: role)
        }
    }
}

// MARK: - Phone / tablet video

private struct VideoPlayerLayout: View {
    let model: VASTPlayerModel
    let request: RenderRequest
    let host: any AdRenderingHost
    let role: VASTPlayerRole

    var body: some View {
        GeometryReader { proxy in
            let below = belowCompanion(in: proxy.size)
            let arrangement = CompanionArrangement.make(container: proxy.size, videoAspect: 16.0 / 9.0,
                                                        companion: below.map { $0.declaredSize ?? CGSize(width: 300, height: 250) },
                                                        isCTV: false)
            ZStack(alignment: .topLeading) {
                Color.black
                PlayerLayerView(player: model.avPlayer.player)
                    .frame(width: arrangement.playerFrame.width, height: arrangement.playerFrame.height)
                PlayerOverlay(model: model, compact: arrangement.playerFrame.height < 160)
                    .frame(width: arrangement.playerFrame.width, height: arrangement.playerFrame.height)
                if let below, let frame = arrangement.companionFrame, let item = model.currentItem {
                    CompanionView(choice: below, adIndex: item.adIndex, player: model, host: host, source: item.source)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                if let endCard = model.endCard {
                    EndCardView(endCard: endCard, model: model, host: host)
                } else if model.phase == .finished {
                    FinishedOverlay(model: model)
                }
                if case .ad = role, request.isFullscreen, model.phase == .finished {
                    CloseButton { model.close() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    /// A companion shown under the player while the ad plays, when one fits.
    private func belowCompanion(in size: CGSize) -> CompanionChoice? {
        guard model.configuration.showsCompanions, model.phase != .finished, let item = model.currentItem, size.width > 0 else { return nil }
        let playerHeight = size.width / (16.0 / 9.0)
        let remaining = size.height - playerHeight - CompanionArrangement.spacing
        guard remaining > 0 else { return nil }
        return CompanionPicker.pick(item.companions, fitting: CGSize(width: size.width, height: remaining))
    }
}

/// Ad label, countdown, skip, play/pause, mute, Learn more and the progress bar over the video.
private struct PlayerOverlay: View {
    let model: VASTPlayerModel
    let compact: Bool

    var body: some View {
        ZStack {
            if model.phase == .loading {
                ProgressView().controlSize(compact ? .small : .regular).tint(.white)
            }
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    AdBadge(model: model, fontSize: compact ? 10 : 12)
                    Spacer()
                    SkipButton(state: model.skipState, fontSize: compact ? 10 : 12, action: model.skip)
                }
                .padding(compact ? 4 : 8)
                Spacer(minLength: 0)
                if model.phase == .playing || model.phase == .loading {
                    HStack(spacing: compact ? 6 : 10) {
                        RoundButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "Pause" : "Play",
                                    size: compact ? 22 : 28, action: model.togglePlayback)
                        RoundButton(symbol: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                    label: model.isMuted ? "Unmute" : "Mute", size: compact ? 22 : 28, action: model.toggleMute)
                        Spacer()
                        if model.showsLearnMore {
                            Button("Learn more", action: model.clickThrough)
                                .buttonStyle(.plain)
                                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, compact ? 8 : 12)
                                .padding(.vertical, compact ? 3 : 5)
                                .background(Capsule().fill(.white))
                        }
                    }
                    .padding(.horizontal, compact ? 4 : 8)
                    .padding(.bottom, compact ? 3 : 6)
                    ProgressBar(fraction: model.progress, height: compact ? 2 : 3)
                }
            }
        }
    }
}

private struct AdBadge: View {
    let model: VASTPlayerModel
    let fontSize: CGFloat

    var body: some View {
        let position = model.adCount > 1 ? "Ad \(model.adNumber) of \(model.adCount)" : "Ad"
        Text("\(position) · \(PlayerClock.format(model.remaining))")
            .font(.system(size: fontSize, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
    }
}

private struct SkipButton: View {
    let state: SkipButtonState
    let fontSize: CGFloat
    let action: () -> Void

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case let .countdown(seconds):
            Text("Skip in \(seconds)")
                .font(.system(size: fontSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.6)))
        case .available:
            Button(action: action) {
                Label("Skip Ad", systemImage: "forward.end.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.75)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.8), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct RoundButton: View {
    let symbol: String
    let label: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3))
                Rectangle().fill(Color.yellow).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: height)
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(10)
        .accessibilityLabel("Close ad")
    }
}

/// After the pod: why nothing plays, or that it ended.
private struct FinishedOverlay: View {
    let model: VASTPlayerModel

    var body: some View {
        if model.startedAds == 0 {
            RendererMessageView(symbol: "exclamationmark.triangle",
                                title: model.lastError.map { "VAST error \($0.rawValue)" } ?? "Nothing to play",
                                detail: model.lastError.map(Self.describe) ?? "The VAST has no linear ad.")
                .foregroundStyle(.white)
        } else {
            Text("Ad finished")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.6)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func describe(_ code: VASTErrorCode) -> String {
        switch code {
        case .noSupportedMedia: "No media file this player can play."
        case .vpaidError: "VPAID media is not executed by the simulator."
        case .fileNotFound: "The media file could not be loaded."
        case .mediaTimeout: "The media file was not ready in time."
        case .mediaDisplayProblem: "The media could not be displayed."
        case .unexpectedLinearity: "The ad is non-linear; the player expects a linear ad."
        default: "See the renderer log and the network monitor."
        }
    }
}

/// The last ad's companion as the end card.
private struct EndCardView: View {
    let endCard: VASTPlayerModel.EndCard
    let model: VASTPlayerModel
    let host: any AdRenderingHost

    var body: some View {
        ZStack {
            Color.black
            let source = model.items.indices.contains(endCard.adIndex) ? model.items[endCard.adIndex].source : model.configuration.source
            CompanionView(choice: endCard.choice, adIndex: endCard.adIndex, player: model, host: host, source: source)
                .frame(maxWidth: endCard.choice.declaredSize?.width, maxHeight: endCard.choice.declaredSize?.height)
                .padding(8)
        }
    }
}

// MARK: - Audio

private struct AudioAdCard: View {
    let model: VASTPlayerModel
    let request: RenderRequest
    let host: any AdRenderingHost

    var body: some View {
        let item = model.currentItem
        let artwork = item.flatMap { CompanionPicker.pick($0.companions, fitting: nil) }
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading,
                                                                       endPoint: .bottomTrailing))
                if let artwork, let item {
                    CompanionView(choice: artwork, adIndex: item.adIndex, player: model, host: host, source: item.source)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "waveform").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxHeight: 180)
            VStack(spacing: 2) {
                Text(item?.title ?? "Audio ad").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(item?.advertiser ?? "Sponsored").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressBar(fraction: model.progress, height: 3).clipShape(Capsule())
            HStack(spacing: 14) {
                AdBadge(model: model, fontSize: 11)
                Spacer()
                SkipButton(state: model.skipState, fontSize: 11, action: model.skip)
                RoundButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", label: model.isPlaying ? "Pause" : "Play", size: 32,
                            action: model.togglePlayback)
                RoundButton(symbol: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: model.isMuted ? "Unmute" : "Mute",
                            size: 32, action: model.toggleMute)
            }
            if model.phase == .finished {
                if model.startedAds == 0 {
                    Text(model.lastError.map { "VAST error \($0.rawValue): \(FinishedOverlay.describe($0))" } ?? "Nothing to play")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if request.isFullscreen {
                    Button("Close") { model.close() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - CTV (10-foot)

/// Full-screen pod playback with remote-style focus: arrows move between Play/Pause and Skip, Return / Space activate,
/// Escape is Back (closes the ad). No click-through.
private struct CTVPlayerLayout: View {
    let model: VASTPlayerModel

    @State private var focus = CTVFocusModel()
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        GeometryReader { proxy in
            let scale = max(0.5, min(proxy.size.width / 1920, proxy.size.height / 1080))
            ZStack {
                Color.black
                PlayerLayerView(player: model.avPlayer.player)
                if model.phase == .loading { ProgressView().controlSize(.large).tint(.white) }
                if model.phase == .finished { FinishedOverlay(model: model) }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        let position = model.adCount > 1 ? "Ad \(model.adNumber) of \(model.adCount)" : "Ad"
                        Text("\(position) · \(PlayerClock.format(model.remaining))")
                            .font(.system(size: 36 * scale, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18 * scale)
                            .padding(.vertical, 8 * scale)
                            .background(Capsule().fill(.black.opacity(0.55)))
                        Spacer()
                        skipControl(scale: scale)
                    }
                    Spacer()
                    HStack {
                        ctvButton(.playPause, scale: scale) {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        }
                        Spacer()
                    }
                    .padding(.bottom, 16 * scale)
                    ProgressBar(fraction: model.progress, height: 6 * scale).clipShape(Capsule())
                }
                .padding(64 * scale)
            }
        }
        .focusable()
        .focused($hasKeyboardFocus)
        .focusEffectDisabled()
        .onAppear { hasKeyboardFocus = true }
        .onChange(of: model.skipState, initial: true) { _, state in
            focus.setAvailable(state == .available ? [.playPause, .skip] : [.playPause])
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .space, .escape]) { press in
            guard let key = Self.remoteKey(press.key) else { return .ignored }
            switch CTVRemote.handle(key, focus: &focus) {
            case .none: break
            case .togglePlayback: model.togglePlayback()
            case .skip: model.skip()
            case .close: model.close()
            }
            return .handled
        }
    }

    static func remoteKey(_ key: KeyEquivalent) -> CTVRemoteKey? {
        switch key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        case .downArrow: .down
        case .return: .select
        case .space: .playPause
        case .escape: .back
        default: nil
        }
    }

    @ViewBuilder private func skipControl(scale: CGFloat) -> some View {
        switch model.skipState {
        case .hidden:
            EmptyView()
        case let .countdown(seconds):
            Text("Skip in \(seconds)")
                .font(.system(size: 30 * scale, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 20 * scale)
                .padding(.vertical, 10 * scale)
                .background(RoundedRectangle(cornerRadius: 8 * scale).fill(.black.opacity(0.6)))
        case .available:
            ctvButton(.skip, scale: scale) {
                Label("Skip Ad", systemImage: "forward.end.fill")
            }
        }
    }

    private func ctvButton(_ control: CTVControl, scale: CGFloat, @ViewBuilder label: () -> some View) -> some View {
        let focused = focus.focused == control
        return label()
            .font(.system(size: 30 * scale, weight: .semibold))
            .foregroundStyle(focused ? .black : .white)
            .padding(.horizontal, 24 * scale)
            .padding(.vertical, 12 * scale)
            .background(RoundedRectangle(cornerRadius: 10 * scale).fill(focused ? .white : .black.opacity(0.6)))
            .scaleEffect(focused ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
            .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
    }
}
