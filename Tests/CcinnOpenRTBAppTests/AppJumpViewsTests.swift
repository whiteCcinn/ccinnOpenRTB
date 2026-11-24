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

    /// A rendered session on `deviceID` (in `posture`) that has opened `url`.
    private func session(_ deviceID: String, opening url: String, fallback: String? = nil, installed: Bool = true,
                         posture: Posture = .portrait) async throws -> AdSession {
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
        harness.session.landscape = posture == .landscape
        harness.session.spanned = posture == .spanned
        harness.session.placement = .interstitial
        await harness.renderAndWait()
        harness.session.appsInstalled = installed
        harness.session.fireManually(.click(assetID: nil))
        return harness.session
    }

    enum Posture {
        case portrait, landscape, spanned
    }

    private struct Jump {
        var name: String
        var device: String
        var url: String
        var fallback: String? = nil
        var installed = true
        var posture = Posture.portrait
        var dark = false
    }

    private var cases: [Jump] {
        [
            Jump(name: "iphone-deep-link", device: "iphone-18-pro", url: "lazada://product/123?utm_source=ad&campaign=ccinn"),
            Jump(name: "iphone-fallback", device: "iphone-18-pro", url: "lazada://product/123", fallback: "https://www.lazada.com.my/p/123?utm_source=ad",
                 installed: false),
            Jump(name: "iphone-app-store", device: "iphone-18-pro", url: "itms-apps://apps.apple.com/app/id785385147"),
            Jump(name: "iphone-nothing", device: "iphone-18-pro", url: "lazada://product/123", installed: false),
            Jump(name: "iphone-landscape", device: "iphone-18-pro", url: "lazada://product/123", posture: .landscape),
            Jump(name: "iphone-dark-browser", device: "iphone-18-pro", url: "https://adv.example/landing?a=1", dark: true),
            Jump(name: "ipad-deep-link", device: "ipad-10", url: "lazada://product/123"),
            Jump(name: "android-intent", device: "pixel-8", url: "intent://item/9?ref=ad#Intent;scheme=shopee;package=com.shopee.my;end"),
            Jump(name: "android-play", device: "pixel-8", url: "intent://item/9#Intent;scheme=shopee;package=com.shopee.my;end", installed: false),
            Jump(name: "android-phone", device: "pixel-8", url: "tel:+60123456789"),
            Jump(name: "duo-spanned", device: "surface-duo", url: "https://www.lazada.com.my/p/123", posture: .spanned),
        ]
    }

    private func picture(of session: AdSession, dark: Bool = false) throws -> Data {
        let size = DeviceFrameStyle(layout: session.layout).outerSize
        let harness = WindowHarness(DeviceView(session: session).background(Color(nsColor: .windowBackgroundColor)), size: size)
        defer { harness.close() }
        harness.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        harness.hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(harness.hosting.bitmapImageRepForCachingDisplay(in: harness.hosting.bounds))
        harness.hosting.cacheDisplay(in: harness.hosting.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    /// Every kind of screen draws over the publisher app: the device looks different until Back.
    @Test func everyScreenDrawsOverTheApp() async throws {
        for jump in cases {
            let session = try await session(jump.device, opening: jump.url, fallback: jump.fallback, installed: jump.installed, posture: jump.posture)
            #expect(session.foreground != nil || session.clickThroughNotice != nil, "\(jump.name)")
            let covered = try picture(of: session, dark: jump.dark)
            session.returnToApp()
            session.dismissClickThroughNotice()
            let back = try picture(of: session, dark: jump.dark)
            #expect(covered != back, "\(jump.name): nothing was drawn")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CCINN_JUMP_SNAPSHOTS"] != nil))
    func snapshots() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CCINN_JUMP_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for jump in cases {
            let session = try await session(jump.device, opening: jump.url, fallback: jump.fallback, installed: jump.installed, posture: jump.posture)
            let size = DeviceFrameStyle(layout: session.layout).outerSize
            let harness = WindowHarness(DeviceView(session: session).background(Color(nsColor: .windowBackgroundColor)), size: size)
            harness.window.appearance = NSAppearance(named: jump.dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .seconds(1))
            harness.hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(harness.hosting.bitmapImageRepForCachingDisplay(in: harness.hosting.bounds))
            harness.hosting.cacheDisplay(in: harness.hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(jump.name + ".png"))
            harness.close()
        }
    }
}
