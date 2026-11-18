import AppKit
import RTBKit
import SwiftUI
import Testing
@testable import CcinnOpenRTB

@Suite("Touch targets")
struct TouchTargetRuleTests {
    @Test func applePlatformsGet44AndAndroidGets50() {
        #expect(TouchTarget.minimumSide(for: RendererFixtures.phone) == 44)
        #expect(TouchTarget.minimumSide(for: RendererFixtures.android) == 50)
        #expect(TouchTarget.minimumSide(for: RendererFixtures.foldable) == 50, "an Android foldable")
        #expect(TouchTarget.minimumSide(for: RendererFixtures.duo) == 50, "an Android dual-screen")
        var iOSFoldable = RendererFixtures.foldable
        iOSFoldable.os = "iOS"
        #expect(TouchTarget.minimumSide(for: iOSFoldable) == 44, "the OS decides, not the form factor")
        var unknown = RendererFixtures.android
        unknown.os = ""
        #expect(TouchTarget.minimumSide(for: unknown) == 50, "the family when the OS is unknown")
    }
}

/// Measures the real hit area by clicking: an AppKit mouse-down / mouse-up pair at points around the visible glyph.
@MainActor
@Suite("Touch targets (hit area, SwiftUI)", .serialized)
struct TouchTargetHitAreaTests {
    @MainActor
    final class Counter {
        var taps = 0
    }

    /// A window with `view` filling its content; clicks are given in content coordinates (origin top-left).
    private final class ClickWindow {
        let window: NSWindow
        let size: CGSize

        @MainActor
        init(_ view: some View, size: CGSize) {
            self.size = size
            let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            hosting.frame = NSRect(origin: .zero, size: size)
            window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFrontRegardless()
            window.makeKey()
        }

        @MainActor
        func click(x: CGFloat, y: CGFloat) {
            let point = NSPoint(x: x, y: size.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(event)
                }
            }
        }

        @MainActor
        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    /// The close control sits in the top-right corner with its glyph centred `glyphCenterInset` from both edges. A click
    /// `side / 2 - 2` from the glyph's centre (in each direction) closes; `side / 2 + 3` does not.
    @Test(arguments: [(RendererFixtures.phone, CGFloat(44)), (RendererFixtures.android, CGFloat(50))])
    func theCloseControlsHitAreaIsTheMinimumTarget(device: DeviceProfile, side: CGFloat) async throws {
        let counter = Counter()
        let size = CGSize(width: 240, height: 240)
        let view = ZStack(alignment: .topTrailing) {
            Color.gray
            CloseControl(label: "Close ad") { counter.taps += 1 }
        }
        .environment(\.minimumTouchTarget, TouchTarget.minimumSide(for: device))
        let harness = ClickWindow(view, size: size)
        defer { harness.close() }
        try await Task.sleep(for: .milliseconds(200))
        let center = CGPoint(x: size.width - CloseControl.glyphCenterInset, y: CloseControl.glyphCenterInset)
        let inside = side / 2 - 2
        for (dx, dy) in [(-inside, 0), (0, inside), (-inside, inside), (0, 0)] {
            let before = counter.taps
            harness.click(x: center.x + dx, y: center.y + dy)
            #expect(await Wait.until(timeout: .seconds(2)) { counter.taps == before + 1 }, "(\(dx), \(dy)) is inside the \(side)-pt target")
        }
        let outside = side / 2 + 3
        let before = counter.taps
        for (dx, dy) in [(-outside, 0), (0, outside)] { harness.click(x: center.x + dx, y: center.y + dy) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.taps == before, "clicks beyond the \(side)-pt target do nothing")
        #expect(CloseControl.glyphSide == 30, "the visible glyph keeps its size")
    }

    @Test(arguments: [(RendererFixtures.phone, CGFloat(44)), (RendererFixtures.android, CGFloat(50))])
    func theSkipButtonIsAtLeastTheMinimumTargetTall(device: DeviceProfile, side: CGFloat) async throws {
        let counter = Counter()
        let size = CGSize(width: 240, height: 120)
        let view = SkipButton(state: .available, fontSize: 12) { counter.taps += 1 }
            .environment(\.minimumTouchTarget, TouchTarget.minimumSide(for: device))
        let harness = ClickWindow(view, size: size)
        defer { harness.close() }
        try await Task.sleep(for: .milliseconds(200))
        // The button is centred in the window; its visible pill is about 24 pt tall.
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        harness.click(x: center.x, y: center.y - (side / 2 - 2))
        #expect(await Wait.until(timeout: .seconds(2)) { counter.taps == 1 }, "the top of the \(side)-pt target")
        harness.click(x: center.x, y: center.y + (side / 2 - 2))
        #expect(await Wait.until(timeout: .seconds(2)) { counter.taps == 2 }, "the bottom of the \(side)-pt target")
        harness.click(x: center.x, y: center.y + side / 2 + 3)
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.taps == 2)
    }
}
