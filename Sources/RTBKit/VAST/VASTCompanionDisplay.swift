import Foundation

public extension VASTCompanion {
    /// The image a player draws for this companion: its first `StaticResource` whose `creativeType` is `image/*`, or that
    /// has no `creativeType` and an image file extension. An image always wins over HTML and iframe resources.
    ///
    /// `nil` when the companion is drawn from an `HTMLResource`, an `IFrameResource` or a script `StaticResource`. Those
    /// open their own click-through, so the tracking plan adds no navigation for them (decisions "Renderer contract
    /// rulings": exactly one navigation per click). Renderers use the same rule to decide what they draw.
    var staticImageURL: String? {
        for resource in resources {
            guard case let .staticResource(url, creativeType) = resource else { continue }
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let type = creativeType?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if type.hasPrefix("image/") || (type.isEmpty && Self.hasImageExtension(trimmed)) { return trimmed }
        }
        return nil
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"]

    private static func hasImageExtension(_ url: String) -> Bool {
        var path = Substring(url)
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<end] }
        guard let dot = path.lastIndex(of: "."), path.index(after: dot) < path.endIndex else { return false }
        return imageExtensions.contains(path[path.index(after: dot)...].lowercased())
    }
}
