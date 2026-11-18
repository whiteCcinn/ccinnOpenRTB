import Foundation
import Observation
import RTBKit
import SwiftUI

/// One VAST companion (below the player, as an audio ad's artwork, or as the end card). Its `creativeView` is reported
/// when it is shown (the image decoded, or the HTML / iframe document loaded); a click goes through the player model.
/// Its requests hang under the hop that delivered the ad's inline document (`VASTPlayerModel.documentRequestID`).
struct CompanionView: View {
    let choice: CompanionChoice
    let adIndex: Int
    let player: VASTPlayerModel
    let host: any AdRenderingHost
    /// `bid 0.0 › VAST › ad 1 of 1 'Title'`.
    let source: String

    var body: some View {
        switch choice.resource {
        case let .image(url):
            CompanionImage(url: url, choice: choice, adIndex: adIndex, player: player, host: host, source: source)
        case .html, .iframe, .script:
            CompanionWeb(choice: choice, adIndex: adIndex, player: player, host: host, source: source)
        }
    }

    static func source(_ adSource: String, companionIndex: Int) -> String {
        adSource + " › Companion \(companionIndex + 1)"
    }
}

private struct CompanionImage: View {
    let url: String
    let choice: CompanionChoice
    let adIndex: Int
    let player: VASTPlayerModel
    let host: any AdRenderingHost
    let source: String

    @State private var state: RemoteImageState = .loading

    var body: some View {
        RemoteImageView(state: state)
            .contentShape(Rectangle())
            .onTapGesture { player.companionClicked(choice, adIndex: adIndex, url: nil) }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Companion ad")
            .task(id: url) {
                state = .loading
                let loaded = await RemoteImageLoader.load(url, host: host, trigger: "companion image",
                                                          source: CompanionView.source(source, companionIndex: choice.companionIndex),
                                                          origin: .document(requestID: player.documentRequestID(adIndex: adIndex)))
                state = loaded
                if loaded.image != nil {
                    player.companionDidAppear(choice, adIndex: adIndex)
                } else if case let .failed(message) = loaded {
                    host.rendererLog(RendererLogEntry(.vast, .warning, "Companion \(choice.companionIndex + 1) did not load: \(message)"))
                }
            }
    }
}

/// An HTML, iframe or script companion in a creative web view (no MRAID; the Simulated-mode sandbox applies). It opens its
/// own click-through: a navigation it makes after a user gesture is reported as `.companionClick` + that navigation.
private struct CompanionWeb: View {
    let choice: CompanionChoice
    let adIndex: Int
    let player: VASTPlayerModel
    let host: any AdRenderingHost
    let source: String

    @State private var controller: CreativeWebController?
    /// Whether the loaded page has its network blocked (every mode but Real).
    @State private var loadedBlocking: Bool?

    /// The page is loaded again whenever the sandbox changes: leaving Real mode (Simulated, Offline) closes a Real-mode
    /// companion's network at once (safety review B1), as the HTML ad does.
    private struct LoadKey: Hashable {
        var companionIndex: Int
        var blocksNetwork: Bool
    }

    var body: some View {
        let blocksNetwork = HTMLAdModel.blocksNetwork(host.monitor)
        ZStack {
            if let controller {
                CreativeWebViewHost(webView: controller.webView, isActive: true)
            }
        }
        .task(id: LoadKey(companionIndex: choice.companionIndex, blocksNetwork: blocksNetwork)) { start(blocksNetwork: blocksNetwork) }
        .onDisappear {
            controller?.teardown()
            controller = nil
            loadedBlocking = nil
        }
    }

    private func start(blocksNetwork: Bool) {
        if let controller {
            guard loadedBlocking != blocksNetwork else { return }
            // A page loaded with another sandbox goes with its web view: nothing it started keeps running.
            controller.teardown()
            self.controller = nil
        }
        loadedBlocking = blocksNetwork
        let created = CreativeWebController(host: host)
        let choice = choice
        let adIndex = adIndex
        let player = player
        created.onEvent = { event in
            switch event {
            case .loaded: player.companionDidAppear(choice, adIndex: adIndex)
            case let .click(url, _): player.companionClicked(choice, adIndex: adIndex, url: url)
            case .failed, .mraidOpen, .mraidState, .mraidCommand: break
            }
        }
        controller = created
        created.load(CreativeWebController.Content(document: CompanionDocument.html(for: choice.resource), mraid: nil,
                                                   blocksNetwork: blocksNetwork, disableScroll: true,
                                                   networkParentID: player.documentRequestID(adIndex: adIndex),
                                                   source: CompanionView.source(source, companionIndex: choice.companionIndex)))
    }
}
