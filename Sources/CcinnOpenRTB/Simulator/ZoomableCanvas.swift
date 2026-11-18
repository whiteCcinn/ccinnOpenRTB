import AppKit
import SwiftUI

/// A Preview-style canvas: the device is drawn at 1 pt = 1 device point inside an `NSScrollView` whose magnification
/// zooms it (fit or fixed levels, pinch to zoom). Scaling the clip view's bounds keeps hit-testing exact for hosted
/// AppKit views such as the creative's web view, unlike a SwiftUI scale effect.
struct ZoomableCanvas<Content: View>: NSViewRepresentable {
    static var padding: CGFloat { 48 }

    let contentSize: CGSize
    @Binding var zoom: ZoomSetting
    /// The magnification actually applied (fit resolves to a number), reported after layout.
    var onMagnification: (Double) -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CanvasScrollView {
        let scrollView = CanvasScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = ZoomSetting.minimum
        scrollView.maxMagnification = ZoomSetting.maximum
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.drawsBackground = true
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        let hosting = NSHostingView(rootView: AnyView(content()))
        hosting.sizingOptions = []
        scrollView.documentView = hosting
        context.coordinator.observe(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: CanvasScrollView, context: Context) {
        context.coordinator.zoom = $zoom
        scrollView.onMagnification = onMagnification
        guard let hosting = scrollView.documentView as? NSHostingView<AnyView> else { return }
        hosting.rootView = AnyView(content().padding(Self.padding))
        let documentSize = CGSize(width: contentSize.width + Self.padding * 2, height: contentSize.height + Self.padding * 2)
        let sizeChanged = hosting.frame.size != documentSize
        if sizeChanged { hosting.frame = CGRect(origin: .zero, size: documentSize) }
        if scrollView.zoom != zoom || sizeChanged {
            scrollView.zoom = zoom
            scrollView.applyZoom()
        }
    }

    static func dismantleNSView(_ scrollView: CanvasScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        var zoom: Binding<ZoomSetting>?
        private var observers: [any NSObjectProtocol] = []

        func observe(_ scrollView: CanvasScrollView) {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: scrollView, queue: .main) { _ in
                MainActor.assumeIsolated { scrollView.isLiveMagnifying = true }
            })
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    scrollView.isLiveMagnifying = false
                    let value = ZoomSetting.clamped(Double(scrollView.magnification))
                    scrollView.zoom = .scale(value)
                    self?.zoom?.wrappedValue = .scale(value)
                }
            })
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}

/// The canvas scroll view: re-fits on resize while zoom is Fit.
final class CanvasScrollView: NSScrollView {
    var zoom: ZoomSetting = .fit
    var isLiveMagnifying = false
    var onMagnification: ((Double) -> Void)?
    private var reported: Double?

    override func layout() {
        super.layout()
        if zoom == .fit { applyZoom() }
    }

    func applyZoom() {
        guard !isLiveMagnifying, let document = documentView else { return }
        let fit = ZoomSetting.fitScale(content: document.frame.size, available: contentSize, margin: 0)
        let target = CGFloat(zoom.magnification(fitting: fit))
        if abs(magnification - target) > 0.0005 {
            setMagnification(target, centeredAt: CGPoint(x: document.frame.midX, y: document.frame.midY))
        }
        let applied = Double(magnification)
        guard reported.map({ abs($0 - applied) > 0.0005 }) ?? true else { return }
        reported = applied
        let callback = onMagnification
        // Reported asynchronously: this runs inside SwiftUI's update pass.
        DispatchQueue.main.async { callback?(applied) }
    }
}

/// Keeps a document smaller than the viewport centred.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let document = documentView.frame
        if rect.width > document.width { rect.origin.x = document.minX - (rect.width - document.width) / 2 }
        if rect.height > document.height { rect.origin.y = document.minY - (rect.height - document.height) / 2 }
        return rect
    }
}

/// Scrolls the mock feed with the trackpad or mouse wheel anywhere over the app (also over the ad, as on a phone).
/// It never takes clicks: hit-testing passes through to the app and the creative.
struct FeedScrollCapture: NSViewRepresentable {
    let session: AdSession

    func makeNSView(context: Context) -> ScrollCaptureView { ScrollCaptureView() }

    func updateNSView(_ view: ScrollCaptureView, context: Context) {
        view.onScroll = { [weak session] delta in session?.scrollFeed(by: delta) }
    }
}

final class ScrollCaptureView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
            return consumed ? nil : event
        }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.removeFromSuperview()
    }

    /// Consumes vertical scrolls over this view; everything else passes on.
    private func consume(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return false }
        // Window points → device points (the canvas magnification), line scrolls → points.
        let scale = abs(convert(NSSize(width: 0, height: 1), from: nil).height)
        let lines: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        onScroll?(event.scrollingDeltaY * lines * (scale.isFinite && scale > 0 ? scale : 1))
        return true
    }
}
