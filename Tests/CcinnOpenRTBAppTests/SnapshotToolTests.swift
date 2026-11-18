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

    /// The frame goes where the video layer is in the view tree: controls drawn above the player (the overlay with the
    /// countdown, Skip and Learn more) stay above it in the capture.
    @Test func whatIsDrawnAboveThePlayerStaysAboveTheFrame() async throws {
        let file = try await SampleMedia.shared.fileURL(for: .video)
        let player = AVPlayer(url: file)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let video = PlayerLayerNSView()
        video.frame = container.bounds
        video.playerLayer?.player = player
        let control = NSView(frame: NSRect(x: 140, y: 70, width: 40, height: 40))
        control.wantsLayer = true
        control.layer?.backgroundColor = NSColor.systemRed.cgColor
        container.addSubview(video)
        container.addSubview(control)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 180), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFrontRegardless()
        defer {
            video.playerLayer?.player = nil
            window.orderOut(nil)
        }
        #expect(await Wait.until(timeout: .seconds(20)) { player.currentItem?.status == .readyToPlay })
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)

        let data = try #require(await SnapshotTool.render(window))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let scale = Double(bitmap.pixelsWide) / 320
        let onControl = try #require(bitmap.colorAt(x: Int(160 * scale), y: Int(90 * scale))?.usingColorSpace(.sRGB))
        #expect(onControl.redComponent > 0.8 && onControl.blueComponent < 0.4, "the control above the player: \(onControl)")
        let beside = try #require(bitmap.colorAt(x: Int(60 * scale), y: Int(90 * scale))?.usingColorSpace(.sRGB))
        #expect(beside.blueComponent > 0.15, "the video frame around it: \(beside)")
        #expect(video.subviews.isEmpty, "the capture leaves the view tree as it was")
    }

    /// A sheet (the Real-mode confirmation listing the tracker hosts) is a window of its own: the capture draws it where it
    /// sits on its parent, so `--snapshot --mode real` shows the confirmation.
    @Test func anAttachedSheetIsInTheCapture() async throws {
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        parentView.wantsLayer = true
        parentView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = parentView
        window.orderFrontRegardless()
        let sheetView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        sheetView.wantsLayer = true
        sheetView.layer?.backgroundColor = NSColor.systemRed.cgColor
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = sheetView
        window.beginSheet(sheet, completionHandler: nil)
        defer {
            window.endSheet(sheet)
            window.orderOut(nil)
        }
        #expect(await Wait.until(timeout: .seconds(5)) { window.attachedSheet === sheet && sheet.isVisible })
        try await Task.sleep(for: .milliseconds(600))  // the sheet's slide-in

        let data = try #require(await SnapshotTool.render(window))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let relative = CGPoint(x: sheet.frame.midX - window.frame.minX, y: sheet.frame.midY - window.frame.minY)
        let scale = Double(bitmap.pixelsWide) / window.frame.width
        // NSBitmapImageRep rows count from the top.
        let pixel = try #require(bitmap.colorAt(x: Int(relative.x * scale), y: bitmap.pixelsHigh - Int(relative.y * scale))?.usingColorSpace(.sRGB))
        #expect(pixel.redComponent > 0.8 && pixel.blueComponent < 0.4, "the sheet, not its parent: \(pixel)")
        let corner = try #require(bitmap.colorAt(x: 4, y: bitmap.pixelsHigh - 4)?.usingColorSpace(.sRGB))
        #expect(corner.blueComponent > corner.redComponent, "the parent around it: \(corner)")
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
