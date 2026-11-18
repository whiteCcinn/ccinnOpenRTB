import CoreGraphics
import RTBKit
import Testing
@testable import CcinnOpenRTB

@Suite("Device frame")
struct DeviceFrameStyleTests {
    private func style(_ id: String, landscape: Bool = false, folded: Bool = false, spanned: Bool = false) throws -> DeviceFrameStyle {
        let device = try #require(DeviceCatalog.device(id: id))
        return DeviceFrameStyle(layout: ScreenLayout(device: device, landscape: landscape, folded: folded, spanned: spanned))
    }

    @Test func faceIDPhoneHasAnEvenBezelAndConcentricCorners() throws {
        let phone = try style("iphone-15-pro")
        let margin = DeviceFrameStyle.outerMargin
        #expect(phone.canvasOrigin == CGPoint(x: margin + 13, y: margin + 13))
        #expect(phone.outerSize == CGSize(width: 393 + 26 + margin * 2, height: 852 + 26 + margin * 2))
        #expect(phone.bodyCornerRadius == CGFloat(68))
        #expect(phone.homeButton == nil)
        #expect(phone.buttons.count == 4)
        #expect(phone.buttons.filter { $0.frame.maxX <= phone.bodyFrame.minX }.count == 3)
    }

    @Test func homeButtonPhoneTurnsItsChinToTheTrailingEdgeInLandscape() throws {
        let portrait = try style("iphone-se-3")
        let home = try #require(portrait.homeButton)
        #expect(home.minY > portrait.canvasOrigin.y + 667)
        let landscape = try style("iphone-se-3", landscape: true)
        #expect(landscape.bezel == DeviceFrameStyle.Insets(top: 18, leading: 96, bottom: 18, trailing: 96))
        let turned = try #require(landscape.homeButton)
        #expect(turned.minX > landscape.canvasOrigin.x + 667)
        #expect(abs(turned.midY - landscape.bodyFrame.midY) < 0.5)
    }

    @Test func televisionStandsOnABase() throws {
        let tv = try style("apple-tv-4k", landscape: true)
        let base = try #require(tv.standBase)
        #expect(tv.standNeck != nil)
        #expect(base.maxY + DeviceFrameStyle.outerMargin == tv.outerSize.height)
        #expect(tv.bodyFrame.width == CGFloat(1956))
        #expect(tv.buttons.isEmpty)
    }

    @Test func everyPartFitsInsideTheOuterFrame() throws {
        for device in DeviceCatalog.all {
            for landscape in [false, true] {
                for posture in [false, true] {
                    let layout = ScreenLayout(device: device, landscape: landscape, folded: posture, spanned: posture)
                    let style = DeviceFrameStyle(layout: layout)
                    let outer = CGRect(origin: .zero, size: style.outerSize)
                    let parts = [style.bodyFrame, style.homeButton, style.earpiece, style.frontCamera, style.standNeck, style.standBase]
                        .compactMap { $0 } + style.buttons.map(\.frame)
                    for part in parts {
                        #expect(outer.insetBy(dx: -0.01, dy: -0.01).contains(part), "\(device.id) landscape \(landscape)")
                    }
                    let canvas = CGRect(origin: style.canvasOrigin, size: layout.canvasSize)
                    #expect(style.bodyFrame.contains(canvas), "\(device.id)")
                }
            }
        }
    }
}
