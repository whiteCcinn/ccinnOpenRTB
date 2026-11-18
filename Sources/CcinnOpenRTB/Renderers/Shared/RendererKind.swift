import RTBKit

/// Which renderer draws a request, decided from the markup alone (pure, so the choice is unit-tested).
enum RendererKind: Equatable {
    case html(String)
    case image(ImageBanner)
    case native(NativeAd)
    case video(ResolvedVAST)
    case audio(ResolvedVAST)
    /// Nothing can be drawn yet (or at all); the message says why.
    case message(title: String, detail: String)

    static func resolve(_ request: RenderRequest) -> RendererKind {
        switch request.candidate.markup {
        case let .html(markup):
            if markup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .message(title: "Empty markup", detail: "The bid's adm is empty.")
            }
            return .html(markup)
        case let .image(banner):
            return .image(banner)
        case .native:
            guard let native = request.native else {
                return .message(title: "Native markup not parsed", detail: "See the inspector for the Native parsing issues.")
            }
            return .native(native)
        case .vast:
            return vastKind(request)
        case .none:
            return .message(title: "No markup in the bid",
                            detail: "The markup is delivered by the win notice (nurl). Real mode fetches it.")
        }
    }

    private static func vastKind(_ request: RenderRequest) -> RendererKind {
        guard let vast = request.vast else {
            return .message(title: "Resolving VAST…", detail: "Following the wrapper chain.")
        }
        if vast.ads.isEmpty {
            let code = vast.failure.map { "VAST error \($0.rawValue)" } ?? "VAST without ads"
            return .message(title: code, detail: "No playable ad in the resolved VAST. Error URLs are in the network monitor.")
        }
        return isAudio(vast, format: request.candidate.format) ? .audio(vast) : .video(vast)
    }

    /// Audio when the bid says so, or when every media file of every linear creative is audio.
    static func isAudio(_ vast: ResolvedVAST, format: AdFormat) -> Bool {
        if format == .audio { return true }
        let types = vast.ads
            .flatMap { $0.inline.creatives }
            .compactMap(\.linear)
            .flatMap(\.mediaFiles)
            .map { ($0.type ?? "").lowercased() }
        return !types.isEmpty && types.allSatisfy { $0.hasPrefix("audio/") }
    }
}
