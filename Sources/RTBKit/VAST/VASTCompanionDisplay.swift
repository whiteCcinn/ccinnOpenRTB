import Foundation

/// What a player shows for a companion, and whether a click on it is the player's navigation. One rule, shared by the
/// renderers and the tracking plan (decisions "Renderer contract rulings": exactly one navigation per click).
public extension VASTCompanion {
    /// The resource a player draws, preferred in this order whatever the document order:
    /// 1. an image `StaticResource`: its `creativeType` is `image/*`, or it has none and its URL has an image extension;
    /// 2. the first non-blank `HTMLResource`;
    /// 3. the first non-blank `IFrameResource`;
    /// 4. a script `StaticResource`: its `creativeType` names JavaScript (VAST 3.0+ `application/x-javascript`), or it has
    ///    none and its URL ends in `.js`. The renderer draws it as `<script src>` inside its HTML container.
    ///
    /// `nil` only when nothing renders (blank resources, or a StaticResource of another type).
    var displayResource: Resource? {
        var html: Resource?
        var iframe: Resource?
        var script: Resource?
        for resource in resources {
            switch resource {
            case let .staticResource(url, creativeType):
                switch Self.staticKind(url: url, creativeType: creativeType) {
                case .image: return resource
                case .script: if script == nil { script = resource }
                case nil: break
                }
            case let .html(markup):
                if html == nil, !Self.isBlank(markup) { html = resource }
            case let .iframe(url):
                if iframe == nil, !Self.isBlank(url) { iframe = resource }
            }
        }
        return html ?? iframe ?? script
    }

    /// Whether the player opens `clickThrough` itself: only when `displayResource` is an image StaticResource. Script,
    /// HTML and iframe companions open their own click-through (the renderer reports the URL), so `.companionClick` plans
    /// the CompanionClickThrough navigation only when this is true, and never on CTV.
    var playerOpensClickThrough: Bool {
        staticImageURL != nil
    }

    /// The image's URL when `displayResource` is an image StaticResource; otherwise `nil`. A view of the same rule.
    var staticImageURL: String? {
        guard case let .staticResource(url, creativeType) = displayResource, Self.staticKind(url: url, creativeType: creativeType) == .image
        else { return nil }
        return url
    }

    private enum StaticKind {
        case image, script
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"]

    /// The kind of a StaticResource: its `creativeType` decides when present, its URL's extension otherwise.
    private static func staticKind(url: String, creativeType: String?) -> StaticKind? {
        guard !isBlank(url) else { return nil }
        let type = creativeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if type.hasPrefix("image/") { return .image }
        if type.contains("javascript") || type.contains("ecmascript") { return .script }
        guard type.isEmpty, let pathExtension = pathExtension(of: url) else { return nil }
        if imageExtensions.contains(pathExtension) { return .image }
        return pathExtension == "js" ? .script : nil
    }

    /// The lower-cased extension of the URL's path (before any query or fragment).
    private static func pathExtension(of url: String) -> String? {
        var path = Substring(url.trimmingCharacters(in: .whitespacesAndNewlines))
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<end] }
        guard let dot = path.lastIndex(of: ".") else { return nil }
        let pathExtension = path[path.index(after: dot)...]
        return pathExtension.isEmpty || pathExtension.contains("/") ? nil : pathExtension.lowercased()
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
