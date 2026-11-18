import AppKit
import CcinnOpenRTBKit
import os
import RTBKit
import SwiftUI

/// Launch arguments for checks of the Network window:
/// - `--demo-network`: fill a demo session with synthetic requests (nothing goes on the network) and open the window;
/// - `--snapshot-network <file.png>` (with `--snapshot-delay <s>`, `--quit-after-snapshot`): render the Network window
///   to a PNG without screen-recording permission;
/// - `--network-layout list|tree|waterfall`, `--network-select <sequence>`: what the snapshot shows.
struct NetworkLaunchSupport: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task { await NetworkDemo.runIfRequested { openWindow(id: NetworkWindowScene.windowID) } }
    }
}

extension View {
    /// Handles `--demo-network` / `--snapshot-network`. Attach once, to the main window's root view.
    func networkLaunchSupport() -> some View { modifier(NetworkLaunchSupport()) }
}

@MainActor
enum NetworkDemo {
    private static var started = false
    /// Kept alive for the whole process (the registry only holds monitors weakly).
    private(set) static var monitor: NetworkMonitor?
    static var requestedLayout: NetworkWindowModel.Layout? {
        argument("--network-layout").flatMap { value in NetworkWindowModel.Layout.allCases.first { $0.rawValue.lowercased() == value.lowercased() } }
    }

    static var requestedSelection: Int? { argument("--network-select").flatMap(Int.init) }

    static func runIfRequested(openWindow: () -> Void) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !started, arguments.contains("--demo-network") || arguments.contains("--snapshot-network") else { return }
        started = true
        if arguments.contains("--demo-network") {
            let demo = NetworkMonitor(transport: DemoTransport(), samples: SampleMedia.shared, publishInterval: .milliseconds(50))
            monitor = demo
            NetworkRegistry.shared.activate(demo)
            openWindow()
            await populate(demo)
        } else {
            openWindow()
        }
        if let path = argument("--snapshot-network") {
            let delay = argument("--snapshot-delay").flatMap(Double.init) ?? 3
            try? await Task.sleep(for: .seconds(delay))
            snapshotNetworkWindow(to: URL(fileURLWithPath: path))
            if arguments.contains("--quit-after-snapshot") { NSApp.terminate(nil) }
        }
    }

    /// A plausible session: an OpenRTB 2.6 video bid with a wrapper chain, Simulated trackers, a blocked creative load,
    /// then Real mode with a redirecting impression, a 404 and a click → navigation. All responses come from
    /// `DemoTransport`; nothing leaves the Mac.
    static func populate(_ monitor: NetworkMonitor) async {
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        func request(_ category: TrackerCategory, _ trigger: String, _ template: String, _ url: String, parent: UUID? = nil,
                     source: String = "bid 0.0 › VAST inline 'Acme' › creative 1", replaced: [String] = [], unknown: [String] = [],
                     script: Bool = false) -> TrackerRequest {
            TrackerRequest(parentID: parent, category: category, trigger: trigger, source: source, template: template, url: url,
                           replacedMacros: replaced, unknownMacros: unknown, isScript: script)
        }
        let win = monitor.dispatch(request(.win, "win", "https://dsp.example.com/win?auction=${AUCTION_ID}&price=${AUCTION_PRICE}&cur=${AUCTION_CURRENCY}",
                                           "https://dsp.example.com/win?auction=a-1029&price=1.23&cur=USD", source: "bid 0.0",
                                           replaced: ["${AUCTION_ID}", "${AUCTION_PRICE}", "${AUCTION_CURRENCY}"]), userAgent: ua)
        try? await Task.sleep(for: .milliseconds(40))
        let tag = "https://adserver.example.com/vast/wrapper.xml?bid=b-7"
        let fetcher = MonitorVASTFetcher(monitor: monitor, userAgent: ua, source: "bid 0.0 › VAST", rootParentID: win, resolving: .url(tag))
        let wrapper = try? await fetcher.fetchVAST(tag, parentRequestID: nil)
        _ = try? await fetcher.fetchVAST("https://cdn.example.net/vast/inline-42.xml", parentRequestID: wrapper?.requestID)
        let media = await monitor.prepareMedia(SampleURL.video, trigger: "media file", source: "bid 0.0 › VAST inline 'Acme' › MediaFiles",
                                               parentID: nil, userAgent: ua)
        _ = media
        monitor.dispatch(request(.billing, "billing", "https://dsp.example.com/bill?p=${AUCTION_PRICE}", "https://dsp.example.com/bill?p=1.23",
                                 source: "bid 0.0", replaced: ["${AUCTION_PRICE}"]), userAgent: ua)
        for (event, path) in [("impression", "imp"), ("creativeView", "cv"), ("start", "start")] {
            try? await Task.sleep(for: .milliseconds(25))
            monitor.dispatch(request(event == "impression" ? .impression : .event, event == "impression" ? "VAST Impression" : "VAST \(event)",
                                     "https://track.example.com/\(path)?ts=[TIMESTAMP]&cb=[CACHEBUSTING]&ua=[DEVICEUA]",
                                     "https://track.example.com/\(path)?ts=2026-11-17T10%3A00%3A00Z&cb=48213377&ua=Mozilla%2F5.0",
                                     replaced: ["[TIMESTAMP]", "[CACHEBUSTING]", "[DEVICEUA]"]), userAgent: ua)
        }
        monitor.dispatch(request(.verification, "verificationNotExecuted", "https://verify.example.org/vne?reason=[REASON]&x=[OMIDPARTNER]",
                                 "https://verify.example.org/vne?reason=2&x=[OMIDPARTNER]", source: "bid 0.0 › VAST inline › AdVerifications",
                                 replaced: ["[REASON]"], unknown: ["[OMIDPARTNER]"]), userAgent: ua)
        monitor.dispatch(request(.impression, "jstracker", "https://measure.example.com/tag.js", "https://measure.example.com/tag.js",
                                 source: "bid 0.0 › native › jstracker", script: true), userAgent: ua)
        let markup = try? await monitor.fetchContent("data:text/html;base64,PGRpdj5BZDwvZGl2Pg==", trigger: "creative markup",
                                                     source: "bid 0.0 › adm", parentID: nil, userAgent: ua)
        monitor.recordCreativeRequest(url: "https://pixel.creative-cdn.example/p.gif?cb=1", kind: "img", blocked: true, parentID: markup?.entryID)
        monitor.recordCreativeRequest(url: "https://fonts.example.com/inter.woff2", kind: "fetch", blocked: true, parentID: markup?.entryID)
        for (index, event) in ["firstQuartile", "midpoint", "thirdQuartile", "complete"].enumerated() {
            try? await Task.sleep(for: .milliseconds(30 + index * 10))
            monitor.dispatch(request(.event, "VAST \(event)", "https://track.example.com/q?e=\(event)&t=[ADPLAYHEAD]",
                                     "https://track.example.com/q?e=\(event)&t=00%3A00%3A0\(4 + index * 3).000", replaced: ["[ADPLAYHEAD]"]), userAgent: ua)
        }

        // Real mode: DemoTransport answers; nothing leaves the Mac.
        monitor.mode = .real
        try? await Task.sleep(for: .milliseconds(30))
        monitor.dispatch(request(.impression, "VAST Impression (2nd ad)", "https://track.example.com/imp2", "https://track.example.com/imp2"),
                         userAgent: ua)
        monitor.dispatch(request(.error, "VAST Error 303", "https://track.example.com/err?code=[ERRORCODE]", "https://track.example.com/err?code=303",
                                 replaced: ["[ERRORCODE]"]), userAgent: ua)
        let click = monitor.dispatch(request(.click, "VAST ClickTracking", "https://track.example.com/click", "https://track.example.com/click"),
                                     userAgent: ua)
        monitor.recordNavigation(url: "https://advertiser.example.com/landing?utm_source=ccinn", trigger: "ClickThrough",
                                 source: "bid 0.0 › VAST inline › VideoClicks", parentID: click)
        monitor.dispatch(request(.loss, "loss (102)", "https://dsp.example.com/loss?r=${AUCTION_LOSS}", "https://dsp.example.com/loss?r=102",
                                 source: "bid 1.0", replaced: ["${AUCTION_LOSS}"]), userAgent: ua)
        await monitor.waitUntilIdle()
        monitor.mode = .simulated
        monitor.flush()
    }

    private static func argument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func snapshotNetworkWindow(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.title.hasPrefix("Network") && $0.isVisible }),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Canned responses for the demo session, with realistic delays. Never touches the network.
final class DemoTransport: HTTPTransport {
    private static let gif = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00,
                                   0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
                                   0x02, 0x02, 0x44, 0x01, 0x00, 0x3B])

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = request.url.absoluteString
        let path = request.url.path
        let delay: Int = path.hasSuffix(".xml") ? 120 : 45 + url.utf8.count % 60
        try await Task.sleep(for: .milliseconds(delay))
        let timings = HTTPTimings(dns: 4, connect: 11, ssl: 7, send: 0.3, wait: Double(delay) - 16, receive: 0.7)
        switch path {
        case "/vast/wrapper.xml":
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/xml; charset=utf-8", "Cache-Control": "no-store"],
                                body: Data(Self.wrapper.utf8), timings: timings)
        case "/vast/inline-42.xml":
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/xml"], body: Data(Self.inline.utf8), timings: timings)
        case "/imp2":
            return HTTPResponse(status: 302, headers: ["Location": "https://sync.partner.example/px?id=42"], timings: timings)
        case "/px":
            return HTTPResponse(status: 302, headers: ["Location": "/px2"], timings: timings)
        case "/err":
            return HTTPResponse(status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found".utf8), timings: timings)
        default:
            return HTTPResponse(status: path == "/click" ? 204 : 200, headers: ["Content-Type": "image/gif", "Server": "demo"],
                                body: path == "/click" ? Data() : Self.gif, timings: timings)
        }
    }

    private static let wrapper = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.2"><Ad id="w1"><Wrapper><AdSystem>Demo Exchange</AdSystem>
      <VASTAdTagURI><![CDATA[https://cdn.example.net/vast/inline-42.xml]]></VASTAdTagURI>
      <Impression><![CDATA[https://exchange.example.com/imp?w=1]]></Impression>
    </Wrapper></Ad></VAST>
    """

    private static let inline = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VAST version="4.2"><Ad id="acme-1"><InLine><AdSystem>Acme</AdSystem><AdTitle>Acme spring sale</AdTitle>
      <Impression><![CDATA[https://track.example.com/imp]]></Impression>
      <Creatives><Creative><Linear><Duration>00:00:15</Duration>
        <MediaFiles><MediaFile delivery="progressive" type="video/mp4" width="1280" height="720"><![CDATA[ccinn-sample://media/sample-15s.mp4]]></MediaFile></MediaFiles>
      </Linear></Creative></Creatives>
    </InLine></Ad></VAST>
    """
}
