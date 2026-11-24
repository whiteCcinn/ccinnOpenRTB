import AppKit
@testable import CcinnOpenRTB
import Foundation
import RTBKit
import SwiftUI
import Testing

/// The device after a click-through: every kind of screen renders (smoke), and with `CCINN_JUMP_SNAPSHOTS=<dir>` the
/// devices are written as PNGs, for looking at them.
@MainActor
@Suite("App jump views", .serialized)
struct AppJumpViewsTests {
    private let display = Fixtures.candidate(.html("<div>ad</div>"))

    /// A rendered session on `deviceID` that has opened `url`.
    private func session(_ deviceID: String, opening url: String, fallback: String? = nil, installed: Bool = true) async throws -> AdSession {
        let harness = SessionHarness(Fixtures.input([display])) { services in
            let base = services.trackingRequests
            services.trackingRequests = { event, candidate, native, vast, context, options in
                base(event, candidate, native, vast, context, options).map { request in
                    guard request.category == .navigation else { return request }
                    var navigation = request
                    navigation.url = url
                    navigation.fallback = fallback
                    return navigation
                }
            }
        }
        await harness.paste()
        harness.session.device = try #require(DeviceCatalog.device(id: deviceID))
        harness.session.placement = .interstitial
        await harness.renderAndWait()
        harness.session.appsInstalled = installed
        harness.session.fireManually(.click(assetID: nil))
        return harness.session
    }

    private var cases: [(name: String, device: String, url: String, fallback: String?, installed: Bool)] {
        [
            ("iphone-deep-link", "iphone-18-pro", "lazada://product/123?utm_source=ad&campaign=ccinn", nil, true),
            ("iphone-fallback", "iphone-18-pro", "lazada://product/123", "https://www.lazada.com.my/p/123?utm_source=ad", false),
            ("iphone-app-store", "iphone-18-pro", "itms-apps://apps.apple.com/app/id785385147", nil, true),
            ("iphone-nothing", "iphone-18-pro", "lazada://product/123", nil, false),
            ("android-intent", "pixel-8", "intent://item/9?ref=ad#Intent;scheme=shopee;package=com.shopee.my;end", nil, true),
            ("android-play", "pixel-8", "intent://item/9#Intent;scheme=shopee;package=com.shopee.my;end", nil, false),
            ("android-phone", "pixel-8", "tel:+60123456789", nil, true),
        ]
    }

    @Test func everyScreenRenders() async throws {
        for jump in cases {
            let session = try await session(jump.device, opening: jump.url, fallback: jump.fallback, installed: jump.installed)
            #expect(session.foreground != nil || session.clickThroughNotice != nil, "\(jump.name)")
            let size = DeviceFrameStyle(layout: session.layout).outerSize
            let harness = WindowHarness(DeviceView(session: session), size: size)
            harness.hosting.layoutSubtreeIfNeeded()
            #expect(harness.hosting.fittingSize.width > 0)
            harness.close()
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CCINN_JUMP_SNAPSHOTS"] != nil))
    func snapshots() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CCINN_JUMP_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for jump in cases {
            let session = try await session(jump.device, opening: jump.url, fallback: jump.fallback, installed: jump.installed)
            let size = DeviceFrameStyle(layout: session.layout).outerSize
            let harness = WindowHarness(DeviceView(session: session).background(Color(nsColor: .windowBackgroundColor)), size: size)
            harness.window.appearance = NSAppearance(named: .aqua)
            try await Task.sleep(for: .seconds(1))
            harness.hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(harness.hosting.bitmapImageRepForCachingDisplay(in: harness.hosting.bounds))
            harness.hosting.cacheDisplay(in: harness.hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(jump.name + ".png"))
            harness.close()
        }
    }
}
