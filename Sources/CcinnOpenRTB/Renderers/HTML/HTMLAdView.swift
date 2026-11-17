import AppKit
import SwiftUI
import WebKit

/// An HTML / MRAID creative in the ad slot. An MRAID `expand()` moves the same web view into a sheet at the expanded
/// size (the simulator clips the slot, so the expanded ad cannot overflow it); closing the sheet is the container's close.
struct HTMLAdView: View {
    let markup: String
    let request: RenderRequest
    let host: any AdRenderingHost

    @State private var model: HTMLAdModel?

    var body: some View {
        let blocksNetwork = HTMLAdModel.blocksNetwork(host.monitor)
        let key = HTMLAdModel.loadKey(markup: markup, request: request, blocksNetwork: blocksNetwork)
        ZStack {
            if let model {
                HTMLAdContent(model: model, request: request)
            } else {
                Color.clear
            }
        }
        .task(id: key) {
            let active = activeModel()
            active.load(markup: markup, request: request, blocksNetwork: blocksNetwork)
            active.setVisibleFraction(request.visibleFraction)
        }
        .onChange(of: request.visibleFraction) { _, fraction in model?.setVisibleFraction(fraction) }
        .onDisappear {
            model?.teardown()
        }
    }

    /// The model, created once per appearance (a torn-down one is replaced when the view comes back).
    private func activeModel() -> HTMLAdModel {
        if let model, !model.isTornDown { return model }
        let created = HTMLAdModel(host: host)
        model = created
        return created
    }
}

private struct HTMLAdContent: View {
    @Bindable var model: HTMLAdModel
    let request: RenderRequest

    var body: some View {
        FullscreenChrome(placement: request.placement, customClose: model.customClose, isClosed: model.isClosed,
                         onClose: { model.containerClose(fullscreen: true) }) {
            ZStack(alignment: .topLeading) {
                if model.isExpanded {
                    expandedPlaceholder
                } else {
                    CreativeWebViewHost(webView: model.controller.webView, isActive: true)
                        .frame(width: model.resizedSize.map { CGFloat($0.width) }, height: model.resizedSize.map { CGFloat($0.height) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if case let .failed(message) = model.status {
                    RendererMessageView(symbol: "exclamationmark.triangle", title: "The creative did not load", detail: message)
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.isExpanded && !model.isClosed },
                                    set: { presented in if !presented, model.isExpanded { model.containerClose(fullscreen: false) } })) {
            ExpandedCreativeSheet(model: model)
        }
    }

    private var expandedPlaceholder: some View {
        RendererMessageView(symbol: "arrow.up.left.and.arrow.down.right", title: "Expanded (MRAID)",
                            detail: "The expanded ad is shown in a sheet.")
    }
}

/// The expanded MRAID creative at its expanded size, with the container's close control (an invisible 50 × 50 region
/// when the creative uses custom close).
private struct ExpandedCreativeSheet: View {
    @Bindable var model: HTMLAdModel

    var body: some View {
        let size = model.expandedSize ?? MRAIDSize(width: 320, height: 480)
        ZStack(alignment: .topTrailing) {
            CreativeWebViewHost(webView: model.controller.webView, isActive: model.isExpanded)
                .frame(width: max(50, CGFloat(size.width)), height: max(50, CGFloat(size.height)))
            closeControl
        }
        .background(Color.black)
    }

    @ViewBuilder private var closeControl: some View {
        if model.customClose {
            Color.clear
                .frame(width: 50, height: 50)
                .contentShape(Rectangle())
                .onTapGesture { model.containerClose(fullscreen: false) }
                .accessibilityLabel("Close expanded ad")
        } else {
            Button {
                model.containerClose(fullscreen: false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.black.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel("Close expanded ad")
        }
    }
}

/// Hosts a web view that lives in a model (not in the view): the same `WKWebView` can move between the slot and the
/// expanded sheet. Only an active host owns it; dismantling never tears the creative down.
struct CreativeWebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if isActive {
            guard webView.superview !== container else { return }
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        } else if webView.superview === container {
            webView.removeFromSuperview()
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for subview in container.subviews { subview.removeFromSuperview() }
    }
}
