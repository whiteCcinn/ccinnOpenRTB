import CoreGraphics
import RTBKit

/// The screen geometry of a device in a given orientation and posture, in points (pure; drives the frame drawing, the
/// mock app layout and `RenderRequest.adSize`).
///
/// - Orientation: `landscape` rotates the stored (natural) screen by 90°. CTV is landscape only and ignores it.
/// - Foldables: `folded` uses the cover screen; unfolded shows the crease along the hinge.
/// - Dual-screen: both screens are always shown with the hinge between them; `spanned` makes the app (and the ad) use
///   both screens, otherwise it lives on the first screen.
struct ScreenLayout: Equatable {
    /// The system UI style of the screen in use (status bar, home indicator, landscape rules).
    enum Chrome: Equatable {
        /// Face ID iPhone screens, including the iPhone Duo's cover screen.
        case iPhone
        /// Touch ID iPhones: no insets in landscape, no home indicator.
        case iPhoneHomeButton
        /// iPads and the iPhone Duo's open screen: a slim status bar kept in landscape.
        case iPad
        case android
        case television
    }

    enum Crease: Equatable {
        case vertical(x: CGFloat)
        case horizontal(y: CGFloat)
    }

    struct Pane: Equatable {
        var frame: CGRect
    }

    let device: DeviceProfile
    /// The area the screens (and the hinge) cover.
    let canvasSize: CGSize
    /// One screen, or two for dual-screen devices (left/top first).
    let panes: [Pane]
    /// Dual-screen: the gap between the screens.
    let hinge: CGRect?
    /// Unfolded foldables: where the fold runs.
    let crease: Crease?
    let isLandscape: Bool
    let isFolded: Bool
    let isSpanned: Bool
    /// The cutout visible on the screen in use (the unfolded main screens of the catalog's foldables have none).
    let cutout: DeviceProfile.Cutout
    /// Safe-area insets of `contentFrame`, rotated with the device (landscape values are approximations of UIKit's).
    let safeArea: DeviceInsets
    let cornerRadius: CGFloat
    let chrome: Chrome
    let showsStatusBar: Bool
    /// Where the app (and the ad) lives: the first screen, or the whole canvas when spanned.
    let contentFrame: CGRect

    /// iOS home indicator inset in landscape.
    static let landscapeHomeIndicatorInset: Double = 21

    init(device: DeviceProfile, landscape: Bool, folded: Bool, spanned: Bool) {
        self.device = device
        let isTV = device.family == .ctv
        let rotated = landscape && !isTV
        let useCover = folded && device.family == .foldable && device.foldedWidth != nil && device.foldedHeight != nil
        let natural = useCover
            ? CGSize(width: device.foldedWidth ?? device.screenWidth, height: device.foldedHeight ?? device.screenHeight)
            : CGSize(width: device.screenWidth, height: device.screenHeight)
        let screen = rotated ? CGSize(width: natural.height, height: natural.width) : natural

        isLandscape = isTV || rotated
        isFolded = useCover
        cornerRadius = device.cornerRadius
        cutout = device.family == .foldable && !useCover ? .none : device.cutout
        let chrome = Self.chrome(of: device, cover: useCover)
        self.chrome = chrome
        let portraitInsets = useCover ? (device.foldedSafeArea ?? device.safeArea) : device.safeArea
        safeArea = Self.safeArea(portraitInsets, chrome: chrome, rotated: rotated)
        showsStatusBar = chrome != .television && !(rotated && (chrome == .iPhone || chrome == .iPhoneHomeButton))

        if device.family == .dualScreen, let hingeWidth = device.hingeWidth, hingeWidth > 0 {
            let gap = CGFloat(hingeWidth)
            if rotated {
                let first = CGRect(origin: .zero, size: screen)
                let second = CGRect(x: 0, y: screen.height + gap, width: screen.width, height: screen.height)
                panes = [Pane(frame: first), Pane(frame: second)]
                hinge = CGRect(x: 0, y: screen.height, width: screen.width, height: gap)
                canvasSize = CGSize(width: screen.width, height: screen.height * 2 + gap)
            } else {
                let first = CGRect(origin: .zero, size: screen)
                let second = CGRect(x: screen.width + gap, y: 0, width: screen.width, height: screen.height)
                panes = [Pane(frame: first), Pane(frame: second)]
                hinge = CGRect(x: screen.width, y: 0, width: gap, height: screen.height)
                canvasSize = CGSize(width: screen.width * 2 + gap, height: screen.height)
            }
            isSpanned = spanned
            contentFrame = spanned ? CGRect(origin: .zero, size: canvasSize) : CGRect(origin: .zero, size: screen)
            crease = nil
        } else {
            panes = [Pane(frame: CGRect(origin: .zero, size: screen))]
            hinge = nil
            canvasSize = screen
            isSpanned = false
            contentFrame = CGRect(origin: .zero, size: screen)
            if device.family == .foldable, !useCover {
                // The fold runs along the hinge, vertical in the natural (book) orientation.
                crease = rotated ? .horizontal(y: screen.height / 2) : .vertical(x: screen.width / 2)
            } else {
                crease = nil
            }
        }
    }

    static func chrome(of device: DeviceProfile, cover: Bool) -> Chrome {
        guard device.family != .ctv else { return .television }
        guard device.os == "iOS" || device.os == "iPadOS" else { return .android }
        switch device.family {
        case .iPhone: return device.cutout == .none ? .iPhoneHomeButton : .iPhone
        case .foldable: return cover ? .iPhone : .iPad
        case .tablet, .androidPhone, .dualScreen, .ctv: return .iPad
        }
    }

    /// Landscape (approximations of UIKit's values): Face ID iPhone screens inset both long sides by the portrait top
    /// inset, hide the status bar and keep a 21 pt home indicator; Touch ID iPhones have no insets; iPad-style and Android
    /// screens keep their status and navigation bars.
    private static func safeArea(_ portrait: DeviceInsets, chrome: Chrome, rotated: Bool) -> DeviceInsets {
        switch chrome {
        case .television:
            return DeviceInsets()
        case .iPhone:
            guard rotated else { return portrait }
            return DeviceInsets(top: 0, leading: portrait.top, bottom: landscapeHomeIndicatorInset, trailing: portrait.top)
        case .iPhoneHomeButton:
            return rotated ? DeviceInsets() : portrait
        case .iPad, .android:
            return rotated ? DeviceInsets(top: portrait.top, bottom: portrait.bottom) : portrait
        }
    }
}
