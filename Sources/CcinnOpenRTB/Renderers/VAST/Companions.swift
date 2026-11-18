import CoreGraphics
import Foundation
import RTBKit

/// How a companion is drawn.
enum CompanionResource: Equatable, Sendable {
    /// An image `StaticResource`, fetched as content.
    case image(url: String)
    /// `HTMLResource`, in the creative web view.
    case html(String)
    /// `IFrameResource`, loaded in the creative web view (subject to the Simulated-mode sandbox).
    case iframe(url: String)
    /// A script `StaticResource`, drawn as `<script src>` in the creative web view.
    case script(url: String)

    /// Only an image's click-through is opened by the tracking plan (`.companionClick` → CompanionClickThrough); HTML,
    /// iframe and script companions open their own, which the player records with `host.navigate`.
    var playerOpensClickThrough: Bool {
        if case .image = self { true } else { false }
    }
}

struct CompanionChoice: Equatable, Sendable {
    var companionIndex: Int
    var companion: VASTCompanion
    var resource: CompanionResource

    /// The declared size, when both dimensions are positive.
    var declaredSize: CGSize? {
        guard let width = companion.width, let height = companion.height, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}

enum CompanionPicker {
    private static let defaultSize = CGSize(width: 300, height: 250)

    /// The resource to draw — the single call site of the shared rule. Switch it to kit-vast's
    /// `VASTCompanion.displayResource` / `playerOpensClickThrough` when they are on this branch.
    static func resource(of companion: VASTCompanion) -> CompanionResource? {
        CompanionDisplayRule.resource(of: companion)
    }

    /// The largest renderable companion that fits `fitting` (below the player); any size when `fitting` is `nil` (an end
    /// card scales it down). Ties keep document order.
    static func pick(_ companions: [IndexedCompanion], fitting: CGSize?) -> CompanionChoice? {
        var best: (choice: CompanionChoice, area: Double)?
        for indexed in companions {
            guard let resource = resource(of: indexed.companion) else { continue }
            let choice = CompanionChoice(companionIndex: indexed.companionIndex, companion: indexed.companion, resource: resource)
            let size = choice.declaredSize ?? defaultSize
            if let fitting, size.width > fitting.width || size.height > fitting.height { continue }
            let area = Double(size.width * size.height)
            if best.map({ area > $0.area }) ?? true { best = (choice, area) }
        }
        return best?.choice
    }
}

/// Local copy of the shared companion rule (decisions "Renderer contract rulings"), until kit-vast's
/// `VASTCompanion.displayResource` reaches this branch: an image `StaticResource` (`creativeType` `image/*`, or untyped
/// with an image file extension), then the first non-blank `HTMLResource`, then `IFrameResource`, then a script
/// `StaticResource`; `nil` when nothing renders.
private enum CompanionDisplayRule {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"]

    static func resource(of companion: VASTCompanion) -> CompanionResource? {
        var html: CompanionResource?
        var iframe: CompanionResource?
        var script: CompanionResource?
        for resource in companion.resources {
            switch resource {
            case let .staticResource(url, creativeType):
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let type = creativeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                if type.isEmpty ? hasImageExtension(trimmed) : type.hasPrefix("image/") { return .image(url: trimmed) }
                if script == nil, type.contains("javascript") || type.contains("ecmascript") { script = .script(url: trimmed) }
            case let .html(markup):
                if html == nil, !markup.allSatisfy(\.isWhitespace) { html = .html(markup) }
            case let .iframe(url):
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                if iframe == nil, !trimmed.isEmpty { iframe = .iframe(url: trimmed) }
            }
        }
        return html ?? iframe ?? script
    }

    private static func hasImageExtension(_ url: String) -> Bool {
        var path = Substring(url)
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<end] }
        guard let dot = path.lastIndex(of: ".") else { return false }
        return imageExtensions.contains(path[path.index(after: dot)...].lowercased())
    }
}

/// The document an HTML / iframe / script companion is drawn in (values escaped).
enum CompanionDocument {
    static func html(for resource: CompanionResource) -> String {
        switch resource {
        case let .html(markup):
            HTMLDocumentBuilder.document(for: markup)
        case let .iframe(url):
            HTMLDocumentBuilder.document(for: """
            <iframe src="\(HTMLEscaping.attribute(url))" style="border:0;width:100%;height:100%;display:block" scrolling="no"></iframe>
            """)
        case let .script(url):
            HTMLDocumentBuilder.document(for: "<script src=\"\(HTMLEscaping.attribute(url))\"></script>")
        case let .image(url):
            HTMLDocumentBuilder.document(for: "<img src=\"\(HTMLEscaping.attribute(url))\" style=\"max-width:100%\">")
        }
    }
}

/// Where the player and a companion go inside the ad's area (pure). The companion sits under a full-width player when
/// both fit; otherwise the player fills the area and the companion waits for the end card.
struct CompanionArrangement: Equatable {
    static let spacing: CGFloat = 12

    var playerFrame: CGRect
    var companionFrame: CGRect?

    static func make(container: CGSize, videoAspect: Double, companion: CGSize?, isCTV: Bool) -> CompanionArrangement {
        let width = clean(container.width)
        let height = clean(container.height)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard !isCTV, let companion, videoAspect.isFinite, videoAspect > 0, width > 0 else {
            return CompanionArrangement(playerFrame: full, companionFrame: nil)
        }
        let playerHeight = width / videoAspect
        let remaining = height - playerHeight - spacing
        guard companion.width <= width, companion.height <= remaining else {
            return CompanionArrangement(playerFrame: full, companionFrame: nil)
        }
        let companionFrame = CGRect(x: ((width - companion.width) / 2).rounded(), y: playerHeight + spacing, width: companion.width,
                                    height: companion.height)
        return CompanionArrangement(playerFrame: CGRect(x: 0, y: 0, width: width, height: playerHeight), companionFrame: companionFrame)
    }

    private static func clean(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}

enum HTMLEscaping {
    /// Text safe inside a double-quoted HTML attribute or element content.
    static func attribute(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
