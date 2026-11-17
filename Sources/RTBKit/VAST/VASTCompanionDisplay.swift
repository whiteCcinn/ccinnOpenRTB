import Foundation

public extension VASTCompanion {
    /// The resource a player draws for this companion. This is the one shared rule: renderers draw it, and the tracking
    /// plan navigates on `.companionClick` only when it is a `StaticResource` (decisions "Renderer contract rulings":
    /// exactly one navigation per click).
    ///
    /// Preference, whatever the document order:
    /// 1. a `StaticResource` that is an image: its `creativeType` is `image/*`, or it has no `creativeType` and its URL has
    ///    an image file extension;
    /// 2. the first non-empty `HTMLResource`;
    /// 3. the first non-empty `IFrameResource`.
    ///
    /// `nil` when nothing renders, for example only a script `StaticResource` (`application/x-javascript`) or an empty
    /// resource. HTML and iframe companions open their own click-through, and the renderer reports that URL itself.
    var displayResource: Resource? {
        var html: Resource?
        var iframe: Resource?
        for resource in resources {
            switch resource {
            case let .staticResource(url, creativeType):
                if Self.isImage(url: url, creativeType: creativeType) { return resource }
            case let .html(markup):
                if html == nil, !Self.isBlank(markup) { html = resource }
            case let .iframe(url):
                if iframe == nil, !Self.isBlank(url) { iframe = resource }
            }
        }
        return html ?? iframe
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"]

    private static func isImage(url: String, creativeType: String?) -> Bool {
        guard !isBlank(url) else { return false }
        let type = creativeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !type.isEmpty { return type.hasPrefix("image/") }
        return hasImageExtension(url.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func hasImageExtension(_ url: String) -> Bool {
        var path = Substring(url)
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<end] }
        guard let dot = path.lastIndex(of: ".") else { return false }
        return imageExtensions.contains(path[path.index(after: dot)...].lowercased())
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
