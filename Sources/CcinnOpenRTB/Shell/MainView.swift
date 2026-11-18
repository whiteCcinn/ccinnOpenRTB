import AppKit
import AVFoundation
import CcinnOpenRTBKit
import RTBKit
import SwiftUI

/// Main window: simulator on the left, response editor and inspector on the right. Owner: app-shell. Each window has its
/// own session (and so its own network monitor and tracking mode).
struct MainView: View {
    @State private var session = AdSession()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            SimulatorPane(session: session)
                .frame(minWidth: 520, idealWidth: 880, maxWidth: .infinity, maxHeight: .infinity)
            InputPanel(session: session)
                .frame(minWidth: 420, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { MainToolbar(session: session) }
        // isPresented, not item: the confirmation's host list completes after the markup is inspected, and an item that
        // changes would dismiss the sheet (and its dismissal would cancel the request).
        .sheet(isPresented: Binding(get: { session.realModeConfirmation != nil }, set: { if !$0 { session.cancelRealMode() } })) {
            RealModeSheetHost(session: session)
        }
        .navigationTitle("CcinnOpenRTB")
        .providesNetworkMonitor(session.monitor)
        .focusedSceneValue(\.adSession, session)
        .task { await LaunchCoordinator.run(session: session, openNetworkWindow: { openWindow(id: NetworkWindowScene.windowID) }) }
    }
}

extension FocusedValues {
    /// The session of the focused main window (menu commands).
    @Entry var adSession: AdSession?
}

/// Applies the launch arguments to the first main window, opens the Network window and takes the snapshot.
@MainActor
enum LaunchCoordinator {
    private static var didRun = false

    static func run(session: AdSession, openNetworkWindow: () -> Void, options: LaunchOptions = LaunchOptions()) async {
        guard !didRun, !options.isEmpty else { return }
        didRun = true
        await options.apply(to: session, samples: session.services.samples())
        if options.opensNetworkWindow { openNetworkWindow() }
        guard options.snapshotPath != nil || options.harPath != nil else { return }
        try? await Task.sleep(for: .seconds(options.snapshotDelay))
        if let path = options.snapshotPath { await SnapshotTool.captureMainWindow(to: URL(fileURLWithPath: path)) }
        if let path = options.harPath { await exportNetwork(of: session.monitor, to: URL(fileURLWithPath: path)) }
        if options.quitAfterSnapshot { NSApp.terminate(nil) }
    }

    /// Writes `monitor`'s log as HAR 1.2 once nothing is in flight.
    static func exportNetwork(of monitor: NetworkMonitor, to url: URL) async {
        await monitor.waitUntilIdle()
        try? monitor.harData().write(to: url, options: .atomic)
    }
}

/// `--snapshot <file.png>`: renders the main window (with its toolbar) into a PNG without screen-recording permission.
/// AppKit's cache draws layer-hosted video (`AVPlayerLayer`) as black, so during the capture each visible player shows its
/// current frame in an image view of its own (`VideoFrameCapture`), at the player's place in the view tree: the controls
/// above the player stay above it. Web content is drawn by the cache. The PNG is written once the window has finished
/// drawing (`SnapshotSettler`): on a first launch under load, text can still be undrawn seconds after the window appears.
@MainActor
enum SnapshotTool {
    static let settleInterval: Duration = .milliseconds(250)
    static let maxSettleAttempts = 20

    static func captureMainWindow(to url: URL) async {
        var settler = SnapshotSettler(maxAttempts: maxSettleAttempts)
        while let window = mainWindow(), let frame = await render(window) {
            if settler.isSettled(after: frame) {
                try? frame.write(to: url)
                return
            }
            try? await Task.sleep(for: settleInterval)
        }
    }

    private static func mainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true } + [NSApp.keyWindow].compactMap { $0 }
        return candidates.first { $0.contentView != nil }
    }

    /// `window` as PNG data, after pending layout and display, with the current video frames in place. The view tree is
    /// left as it was.
    static func render(_ window: NSWindow) async -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        let frames = await VideoFrameCapture.frames(in: view)
        let standIns = frames.map { frame in
            let imageView = NSImageView(frame: frame.player.bounds)
            imageView.image = NSImage(cgImage: frame.image, size: .zero)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            frame.player.addSubview(imageView)
            return imageView
        }
        defer { standIns.forEach { $0.removeFromSuperview() } }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// The current frame of each visible video player in a view tree, for snapshots. Only local media (the built-in samples,
/// `data:` media) is read: a remote stream is never fetched again for a snapshot.
@MainActor
enum VideoFrameCapture {
    struct Frame {
        var player: PlayerLayerNSView
        var image: CGImage
    }

    static func frames(in root: NSView) async -> [Frame] {
        var frames: [Frame] = []
        for view in players(in: root) {
            guard let item = view.playerLayer?.player?.currentItem, let asset = item.asset as? AVURLAsset, asset.url.isFileURL,
                  let image = await image(of: asset, at: item.currentTime()) else { continue }
            frames.append(Frame(player: view, image: image))
        }
        return frames
    }

    private static func players(in view: NSView) -> [PlayerLayerNSView] {
        guard !view.isHidden else { return [] }
        let own = (view as? PlayerLayerNSView).map { [$0] } ?? []
        return own + view.subviews.flatMap { players(in: $0) }
    }

    private static func image(of asset: AVURLAsset, at time: CMTime) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: time.isValid && time.isNumeric ? time : .zero).image
    }
}

/// Decides when a window has finished drawing: two identical consecutive frames, or the latest frame once `maxAttempts`
/// frames were taken (a playing video or a countdown never settles).
struct SnapshotSettler {
    let maxAttempts: Int
    private(set) var attempts = 0
    private var previous: Data?

    init(maxAttempts: Int) {
        self.maxAttempts = maxAttempts
    }

    /// Whether `frame`, the newest capture, is the one to write.
    mutating func isSettled(after frame: Data) -> Bool {
        attempts += 1
        defer { previous = frame }
        return frame == previous || attempts >= maxAttempts
    }
}
