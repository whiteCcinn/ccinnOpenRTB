import AppKit
import AVFoundation
import SwiftUI

/// Shows an `AVPlayer` (aspect-fit on black). The view only displays; the engine owns the player.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerNSView {
        PlayerLayerNSView()
    }

    func updateNSView(_ view: PlayerLayerNSView, context: Context) {
        if view.playerLayer?.player !== player { view.playerLayer?.player = player }
    }

    static func dismantleNSView(_ view: PlayerLayerNSView, coordinator: ()) {
        view.playerLayer?.player = nil
    }
}

final class PlayerLayerNSView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer?.videoGravity = .resizeAspect
        playerLayer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}
