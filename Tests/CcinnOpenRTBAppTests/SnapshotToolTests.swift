import AppKit
import AVFoundation
import CcinnOpenRTBKit
import Testing
@testable import CcinnOpenRTB

/// `--snapshot` renders the window without screen-recording permission. AppKit's cache draws an `AVPlayerLayer` as black,
/// so the tool draws each visible player's current frame into the capture itself.
@MainActor
@Suite("Snapshot tool", .serialized)
struct SnapshotToolTests {
    @Test func theVideoFrameIsInTheCaptureNotAppKitsBlack() async throws {
        let file = try await SampleMedia.shared.fileURL(for: .video)
        let player = AVPlayer(url: file)
        let view = PlayerLayerNSView()
        view.playerLayer?.player = player
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 240), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            view.playerLayer?.player = nil
            window.orderOut(nil)
        }
        let ready = await Wait.until(timeout: .seconds(20)) { player.currentItem?.status == .readyToPlay }
        #expect(ready)
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)

        let data = try #require(await SnapshotTool.render(window))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        // 16:9 in 4:3: the frame fills the middle, black bars above and below.
        let middle = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(middle.blueComponent > 0.15, "the sample's gradient, not black: \(middle)")
        let bar = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 2)?.usingColorSpace(.sRGB))
        #expect(bar.blueComponent < 0.05, "aspect fit: the letterbox stays black: \(bar)")
    }

    @Test func aWindowWithoutVideoIsCapturedAsAppKitDrawsIt() async throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemRed.cgColor
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 60), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let data = try #require(await SnapshotTool.render(window))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.8 && color.blueComponent < 0.4, "\(color)")
    }
}
