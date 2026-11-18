import CoreGraphics
import RTBKit

/// The physical frame drawn around a device's screens (pure geometry, in device points).
///
/// The canvas (`ScreenLayout.canvasSize`: the screens and, for dual-screen devices, the hinge gap) sits inside the body
/// at `canvasOrigin`. Bezels and buttons are described in the natural (portrait) orientation and rotated with the device:
/// landscape turns the device counter-clockwise, so the natural top edge becomes the leading edge.
struct DeviceFrameStyle: Equatable {
    enum Body: Equatable {
        case phone, tablet, television
    }

    struct Insets: Equatable {
        var top: CGFloat
        var leading: CGFloat
        var bottom: CGFloat
        var trailing: CGFloat

        /// The same bezel after rotating the device a quarter turn counter-clockwise.
        var rotatedCounterClockwise: Insets { Insets(top: trailing, leading: top, bottom: leading, trailing: bottom) }
    }

    /// A hardware button protruding from the body, in outer-frame coordinates.
    struct Button: Equatable {
        var frame: CGRect
    }

    /// Room around the body for buttons that stick out (and the shadow).
    static let outerMargin: CGFloat = 6
    static let buttonDepth: CGFloat = 3.5

    let body: Body
    let bezel: Insets
    /// The body (canvas + bezel).
    let bodyFrame: CGRect
    let bodyCornerRadius: CGFloat
    let screenCornerRadius: CGFloat
    /// Where the canvas starts inside the outer frame.
    let canvasOrigin: CGPoint
    let outerSize: CGSize
    /// iPhone SE: Touch ID home button in the chin.
    let homeButton: CGRect?
    /// iPhone SE: earpiece slot and front camera in the forehead.
    let earpiece: CGRect?
    let frontCamera: CGRect?
    /// TV: neck and base below the panel.
    let standNeck: CGRect?
    let standBase: CGRect?
    let buttons: [Button]

    init(layout: ScreenLayout) {
        let device = layout.device
        let canvas = layout.canvasSize
        let rotated = layout.isLandscape && device.family != .ctv
        let natural: Insets
        var hasHomeButton = false
        switch device.family {
        case .foldable where device.make == "Apple":
            // iPhone Duo: thin, even bezel around both screens.
            natural = Insets(top: 9, leading: 9, bottom: 9, trailing: 9)
            body = .phone
        case .iPhone where device.cutout == .none:
            // Home-button iPhone: tall forehead and chin.
            natural = Insets(top: 96, leading: 18, bottom: 96, trailing: 18)
            hasHomeButton = true
            body = .phone
        case .iPhone:
            natural = Insets(top: 13, leading: 13, bottom: 13, trailing: 13)
            body = .phone
        case .androidPhone, .foldable:
            natural = Insets(top: 11, leading: 10, bottom: 12, trailing: 10)
            body = .phone
        case .dualScreen:
            natural = Insets(top: 40, leading: 10, bottom: 40, trailing: 10)
            body = .phone
        case .tablet:
            natural = Insets(top: 24, leading: 24, bottom: 24, trailing: 24)
            body = .tablet
        case .ctv:
            natural = Insets(top: 18, leading: 18, bottom: 30, trailing: 18)
            body = .television
        }
        bezel = rotated ? natural.rotatedCounterClockwise : natural
        let margin = Self.outerMargin
        let bodySize = CGSize(width: canvas.width + bezel.leading + bezel.trailing, height: canvas.height + bezel.top + bezel.bottom)
        bodyFrame = CGRect(x: margin, y: margin, width: bodySize.width, height: bodySize.height)
        canvasOrigin = CGPoint(x: margin + bezel.leading, y: margin + bezel.top)
        screenCornerRadius = layout.isFolded ? max(18, layout.cornerRadius * 0.8) : layout.cornerRadius
        let thinnest = min(bezel.top, bezel.leading, bezel.bottom, bezel.trailing)
        bodyCornerRadius = switch body {
        case .television: 10
        case .phone where hasHomeButton: 56
        default: screenCornerRadius + thinnest
        }

        if body == .television {
            let neck = CGSize(width: min(220, canvas.width * 0.12), height: 70)
            let base = CGSize(width: min(760, canvas.width * 0.4), height: 22)
            let neckFrame = CGRect(x: bodyFrame.midX - neck.width / 2, y: bodyFrame.maxY, width: neck.width, height: neck.height)
            standNeck = neckFrame
            standBase = CGRect(x: bodyFrame.midX - base.width / 2, y: neckFrame.maxY, width: base.width, height: base.height)
            outerSize = CGSize(width: bodyFrame.maxX + margin, height: neckFrame.maxY + base.height + margin)
        } else {
            standNeck = nil
            standBase = nil
            outerSize = CGSize(width: bodyFrame.maxX + margin, height: bodyFrame.maxY + margin)
        }

        if hasHomeButton {
            let diameter: CGFloat = 58
            let chin = rotated ? CGRect(x: bodyFrame.maxX - bezel.trailing, y: bodyFrame.minY, width: bezel.trailing, height: bodyFrame.height)
                : CGRect(x: bodyFrame.minX, y: bodyFrame.maxY - bezel.bottom, width: bodyFrame.width, height: bezel.bottom)
            homeButton = CGRect(x: chin.midX - diameter / 2, y: chin.midY - diameter / 2, width: diameter, height: diameter)
            let forehead = rotated ? CGRect(x: bodyFrame.minX, y: bodyFrame.minY, width: bezel.leading, height: bodyFrame.height)
                : CGRect(x: bodyFrame.minX, y: bodyFrame.minY, width: bodyFrame.width, height: bezel.top)
            let slot = CGSize(width: 50, height: 6)
            earpiece = rotated ? CGRect(x: forehead.midX - slot.height / 2, y: forehead.midY - slot.width / 2, width: slot.height, height: slot.width)
                : CGRect(x: forehead.midX - slot.width / 2, y: forehead.midY - slot.height / 2, width: slot.width, height: slot.height)
            let camera: CGFloat = 10
            frontCamera = rotated ? CGRect(x: forehead.midX - camera / 2, y: forehead.midY - slot.width / 2 - 22, width: camera, height: camera)
                : CGRect(x: forehead.midX - slot.width / 2 - 22, y: forehead.midY - camera / 2, width: camera, height: camera)
        } else {
            homeButton = nil
            earpiece = nil
            frontCamera = device.family == .tablet ? Self.tabletCamera(bodyFrame: bodyFrame, bezel: bezel, rotated: rotated) : nil
        }
        buttons = Self.buttons(for: device.family, bodyFrame: bodyFrame, rotated: rotated)
    }

    /// iPad (10th gen) and iPad Pro: the front camera sits on the landscape top edge (the portrait trailing side).
    private static func tabletCamera(bodyFrame: CGRect, bezel: Insets, rotated: Bool) -> CGRect {
        let size: CGFloat = 7
        if rotated {
            return CGRect(x: bodyFrame.midX - size / 2, y: bodyFrame.minY + (bezel.top - size) / 2, width: size, height: size)
        }
        return CGRect(x: bodyFrame.maxX - (bezel.trailing + size) / 2, y: bodyFrame.midY - size / 2, width: size, height: size)
    }

    /// Side buttons as (natural edge, start, length) along the portrait body, rotated for landscape.
    private static func buttons(for family: DeviceProfile.Family, bodyFrame: CGRect, rotated: Bool) -> [Button] {
        enum Edge { case left, right, top }
        let layout: [(Edge, CGFloat, CGFloat)]
        switch family {
        case .iPhone: layout = [(.left, 0.14, 0.035), (.left, 0.22, 0.07), (.left, 0.31, 0.07), (.right, 0.25, 0.11)]
        case .androidPhone: layout = [(.right, 0.2, 0.07), (.right, 0.32, 0.13)]
        case .foldable: layout = [(.right, 0.24, 0.08), (.right, 0.36, 0.12)]
        case .dualScreen: layout = [(.right, 0.18, 0.08), (.right, 0.3, 0.1)]
        case .tablet: layout = [(.top, 0.82, 0.07), (.right, 0.08, 0.05), (.right, 0.14, 0.05)]
        case .ctv: layout = []
        }
        let naturalSize = rotated ? CGSize(width: bodyFrame.height, height: bodyFrame.width) : bodyFrame.size
        let depth = buttonDepth
        return layout.map { edge, start, length in
            // Natural frame relative to the body's top-left corner.
            let natural: CGRect = switch edge {
            case .left: CGRect(x: -depth, y: naturalSize.height * start, width: depth, height: naturalSize.height * length)
            case .right: CGRect(x: naturalSize.width, y: naturalSize.height * start, width: depth, height: naturalSize.height * length)
            case .top: CGRect(x: naturalSize.width * start, y: -depth, width: naturalSize.width * length, height: depth)
            }
            // Counter-clockwise quarter turn: (x, y) → (y, W − x).
            let turned = rotated ? CGRect(x: natural.minY, y: naturalSize.width - natural.maxX, width: natural.height, height: natural.width)
                : natural
            return Button(frame: turned.offsetBy(dx: bodyFrame.minX, dy: bodyFrame.minY))
        }
    }
}
