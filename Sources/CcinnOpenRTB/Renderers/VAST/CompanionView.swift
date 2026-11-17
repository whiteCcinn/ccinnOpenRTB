import Foundation
import Observation
import RTBKit
import SwiftUI

/// One VAST companion (below the player, as an audio ad's artwork, or as the end card). Its `creativeView` is reported
/// when it is shown (the image decoded, or the HTML / iframe document loaded); a click goes through the player model.
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
        case .html, .iframe:
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
                                                          source: CompanionView.source(source, companionIndex: choice.companionIndex))
                state = loaded
                if loaded.image != nil {
                    player.companionDidAppear(choice, adIndex: adIndex)
                } else if case let .failed(message) = loaded {
                    host.rendererLog(RendererLogEntry(.vast, .warning, "Companion \(choice.companionIndex + 1) did not load: \(message)"))
                }
            }
    }
}

/// An HTML or iframe companion in a creative web view (no MRAID; the Simulated-mode sandbox applies).
private struct CompanionWeb: View {
    let choice: CompanionChoice
    let adIndex: Int
    let player: VASTPlayerModel
    let host: any AdRenderingHost
    let source: String

    @State private var controller: CreativeWebController?

    var body: some View {
        ZStack {
            if let controller {
                CreativeWebViewHost(webView: controller.webView, isActive: true)
            }
        }
        .task(id: choice.companionIndex) { start() }
        .onDisappear {
            controller?.teardown()
            controller = nil
        }
    }

    private func start() {
        guard controller == nil else { return }
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
        created.load(CreativeWebController.Content(document: Self.document(for: choice.resource), mraid: nil,
                                                   blocksNetwork: HTMLAdModel.blocksNetwork(host.monitor), disableScroll: true,
                                                   networkParentID: nil, source: CompanionView.source(source, companionIndex: choice.companionIndex)))
    }

    static func document(for resource: CompanionResource) -> String {
        switch resource {
        case let .html(markup):
            return HTMLDocumentBuilder.document(for: markup)
        case let .iframe(url):
            return HTMLDocumentBuilder.document(for: """
            <iframe src="\(HTMLEscaping.attribute(url))" style="border:0;width:100%;height:100%;display:block" scrolling="no"></iframe>
            """)
        case let .image(url):
            return HTMLDocumentBuilder.document(for: "<img src=\"\(HTMLEscaping.attribute(url))\" style=\"max-width:100%\">")
        }
    }
}
