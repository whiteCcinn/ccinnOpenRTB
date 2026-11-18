import CoreGraphics
import Foundation
import RTBKit

/// One industry icon (AdChoices …) the player draws over the video (VAST 4.1 `Icons/Icon`): its StaticResource image at
/// its position and size (VAST pixels, drawn as points), from `offset` for `duration` seconds of the ad.
struct PlayerIcon: Equatable, Sendable, Identifiable {
    /// Index into the ad's `icons` (wrapper icons first): the `iconIndex` of `.iconView` / `.iconClick`.
    let iconIndex: Int
    let program: String?
    let imageURL: String
    let size: CGSize
    let x: VASTIcon.HorizontalPosition
    let y: VASTIcon.VerticalPosition
    /// Seconds into the ad before it shows.
    let offset: Double
    /// Seconds it stays; `nil`: until the ad ends.
    let duration: Double?

    var id: Int { iconIndex }

    func isVisible(at playhead: Double) -> Bool {
        guard playhead.isFinite, playhead >= offset else { return false }
        guard let duration else { return true }
        return playhead < offset + duration
    }

    /// Where it sits in a player of `player` size: never larger than the player, always inside it.
    func frame(in player: CGSize) -> CGRect {
        let bounds = CGSize(width: max(0, player.width.isFinite ? player.width : 0), height: max(0, player.height.isFinite ? player.height : 0))
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let left: CGFloat = switch x {
        case .left: 0
        case .right: bounds.width - width
        case let .pixels(value): CGFloat(value)
        }
        let top: CGFloat = switch y {
        case .top: 0
        case .bottom: bounds.height - height
        case let .pixels(value): CGFloat(value)
        }
        return CGRect(x: min(max(0, left), bounds.width - width), y: min(max(0, top), bounds.height - height), width: width, height: height)
    }
}

enum VASTIconPlan {
    /// The size of an icon that declares none.
    static let defaultSize = CGSize(width: 20, height: 20)
    /// The largest size taken from the markup (VAST pixels).
    static let maxSide = 4_096

    /// The icons the player draws: those with an image StaticResource (HTML, iframe and script icons are not run); for one
    /// `program`, the last — the inline ad's over a wrapper's (wrapper icons come first). Document order.
    static func icons(_ icons: [VASTIcon]) -> [PlayerIcon] {
        var drawn: [PlayerIcon] = []
        for (index, icon) in icons.enumerated() {
            guard let url = imageURL(of: icon) else { continue }
            let program = icon.program?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let program, !program.isEmpty { drawn.removeAll { $0.program?.lowercased() == program } }
            drawn.append(PlayerIcon(iconIndex: index, program: icon.program, imageURL: url,
                                    size: CGSize(width: side(icon.width) ?? defaultSize.width, height: side(icon.height) ?? defaultSize.height),
                                    x: icon.xPosition ?? .right, y: icon.yPosition ?? .top,
                                    offset: max(0, icon.offset.flatMap { $0.isFinite ? $0 : nil } ?? 0),
                                    duration: icon.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }))
        }
        return drawn
    }

    private static func side(_ value: Int?) -> CGFloat? {
        guard let value, value > 0 else { return nil }
        return CGFloat(min(value, maxSide))
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic"]

    private static func imageURL(of icon: VASTIcon) -> String? {
        for resource in icon.resources {
            guard case let .staticResource(url, creativeType) = resource else { continue }
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let type = creativeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !type.isEmpty {
                if type.hasPrefix("image/") { return trimmed }
                continue
            }
            let path = URLComponents(string: trimmed)?.path ?? trimmed
            if imageExtensions.contains((path as NSString).pathExtension.lowercased()) { return trimmed }
        }
        return nil
    }
}
