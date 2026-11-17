import AppKit
import SwiftUI

/// An image the renderer fetched through the host (`fetchContent`, recorded as content in both modes).
enum RemoteImageState: Equatable {
    case loading
    case loaded(NSImage)
    case failed(String)

    var image: NSImage? {
        if case let .loaded(image) = self { image } else { nil }
    }

    static func == (lhs: RemoteImageState, rhs: RemoteImageState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading): true
        case let (.loaded(left), .loaded(right)): left === right
        case let (.failed(left), .failed(right)): left == right
        default: false
        }
    }
}

enum RemoteImageLoader {
    /// Fetches and decodes `url`. Never throws: a failure is a state the view shows.
    @MainActor
    static func load(_ url: String, host: any AdRenderingHost, trigger: String, source: String) async -> RemoteImageState {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("No image URL") }
        do {
            let data = try await host.fetchContent(trimmed, trigger: trigger, source: source)
            guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else {
                return .failed("Not an image (\(data.count) bytes)")
            }
            return .loaded(image)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Draws a loaded image scaled to fit (or fill), a spinner while loading, a placeholder on failure.
struct RemoteImageView: View {
    let state: RemoteImageState
    var contentMode: ContentMode = .fit
    var placeholderSymbol = "photo"

    var body: some View {
        switch state {
        case .loading:
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.1))
                ProgressView().controlSize(.small)
            }
        case let .loaded(image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: contentMode)
        case let .failed(message):
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.1))
                Image(systemName: placeholderSymbol).foregroundStyle(.secondary)
            }
            .help(message)
        }
    }
}
