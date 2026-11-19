import SwiftUI
import WebKit

/// The Prebid page, in the window (a page off screen gets its timers throttled).
struct PrebidWebView: NSViewRepresentable {
    let host: PrebidHost

    func makeNSView(context: Context) -> WKWebView { host.webView }
    func updateNSView(_ webView: WKWebView, context: Context) {}
}
