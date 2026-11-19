import CcinnOpenRTBKit
import Foundation
import RTBKit
import Testing
@testable import CcinnOpenRTB

private let syncStart = "https://ssp.example/usersync?bidder=dsp&gdpr=${GDPR}&gdpr_consent=${GDPR_CONSENT_755}"
private let syncStartExpanded = "https://ssp.example/usersync?bidder=dsp&gdpr=1&gdpr_consent=CPtc"
private let dspPixel = "https://sync.dsp.example/pixel?redir=https%3A%2F%2Fssp.example%2Fsetuid%3Fbidder%3Ddsp%26uid%3D%24UID"
private let setuid = "https://ssp.example/setuid?bidder=dsp&uid=abc123"

/// A target whose device and monitor the Sync tab uses.
@MainActor
private final class SyncTarget: SyncTargetProviding {
    let monitor: NetworkMonitor
    var device: DeviceProfile

    init(monitor: NetworkMonitor, device: DeviceProfile = DeviceCatalog.defaultDevice) {
        self.monitor = monitor
        self.device = device
    }
}

@MainActor
private func chain(_ transport: ScriptedTransport, setuidURL: String = setuid) {
    transport.answer(syncStartExpanded, .init(status: 302, headers: ["Location": dspPixel, "Set-Cookie": "ssp_sid=s1; Secure; SameSite=None; Path=/"]))
    transport.answer(dspPixel, .init(status: 302, headers: ["Location": setuidURL, "Set-Cookie": "uid=abc123; Domain=dsp.example; Max-Age=3600; Secure; SameSite=None"]))
    transport.answer(setuidURL, .init(headers: ["Content-Type": "image/gif"]))
}

@MainActor
@Suite("Sync: model", .serialized)
struct SyncModelTests {
    private func model(_ transport: ScriptedTransport, device: DeviceProfile = DeviceCatalog.defaultDevice) -> (SyncModel, SyncTarget) {
        let target = SyncTarget(monitor: NetworkMonitor(transport: transport, publishInterval: .zero), device: device)
        let model = SyncModel(target: target)
        model.startURL = syncStart
        model.consent = SyncConsent(gdprApplies: true, tcString: "CPtc")
        return (model, target)
    }

    private func device(_ id: String) throws -> DeviceProfile { try #require(DeviceCatalog.device(id: id)) }

    /// Web cookie mapping runs in a browser: the device picks its browser (Safari on Apple phones and tablets, Chrome on
    /// Android), TVs have none (an app's own requests); the browser decides both the cookie policy and the User-Agent.
    @Test func theBrowserFollowsTheDevice() throws {
        #expect(SyncBrowser.default(for: DeviceCatalog.defaultDevice) == .safari)
        #expect(SyncBrowser.default(for: try device("ipad-pro-11-m5")) == .safari)
        #expect(SyncBrowser.default(for: try device("pixel-8")) == .chrome)
        #expect(SyncBrowser.default(for: try device("apple-tv-4k")) == .tvApp)
        #expect(SyncBrowser.default(for: try device("roku-express")) == .tvApp)
        #expect(SyncBrowser.safari.policy == .blockThirdParty)
        #expect(SyncBrowser.iosApp.policy == .blockThirdParty)
        #expect(SyncBrowser.androidApp.policy == .blockThirdParty, "Android WebView: acceptThirdPartyCookies is off by default")
        #expect(SyncBrowser.chrome.policy == .allowThirdParty)
        #expect(SyncBrowser.firefox.policy == .partitioned)
        let phone = DeviceCatalog.defaultDevice
        #expect(SyncBrowser.safari.userAgent(for: phone).contains("Version/\(phone.osVersion)"))
        #expect(SyncBrowser.safari.userAgent(for: phone).hasSuffix("Safari/604.1"))
        #expect(SyncBrowser.iosApp.userAgent(for: phone) == phone.userAgent)
        #expect(SyncBrowser.chrome.userAgent(for: try device("pixel-8")).contains("Chrome/"))
        #expect(!SyncBrowser.chrome.userAgent(for: try device("pixel-8")).contains("; wv"))
        #expect(SyncBrowser.androidApp.userAgent(for: try device("pixel-8")).contains("; wv"))
        #expect(SyncBrowser.allCases.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }

    @Test func aRunFillsConsentFollowsTheChainAndReadsTheMapping() async throws {
        let transport = ScriptedTransport()
        chain(transport)
        let (model, target) = model(transport, device: try device("pixel-8"))

        await model.run()?.value

        let run = try #require(model.lastRun)
        #expect(run.startURL == syncStartExpanded)
        #expect(Set(run.replacedMacros) == ["${GDPR}", "${GDPR_CONSENT_755}"])
        #expect(run.chain.map(\.status) == [302, 302, 200])
        #expect(run.mappings == [SyncRun.IDMapping(partner: "dsp", id: "abc123", parameter: "uid", hopIndex: 2)])
        #expect(run.leftovers.isEmpty)
        #expect(run.failure == nil)
        #expect(Set(model.session.jar.cookies.map(\.name)) == ["ssp_sid", "uid"])
        let first = try #require(transport.requests.first)
        #expect(first.method == "GET")
        #expect(first.headers["Referer"] == "https://news.example/")
        #expect(first.headers["User-Agent"] == SyncBrowser.chrome.userAgent(for: target.device))
        #expect(target.monitor.liveEntries.first?.category == .userSync)
        #expect(model.runCount == 1)
    }

    /// The partner left `$UID` in the URL it redirected to: the match is lost, and the run says where.
    @Test func anUnsubstitutedUIDIsFlagged() async throws {
        let transport = ScriptedTransport()
        chain(transport, setuidURL: "https://ssp.example/setuid?bidder=dsp&uid=$UID")
        let (model, _) = model(transport, device: try device("pixel-8"))

        await model.run()?.value

        let run = try #require(model.lastRun)
        #expect(run.leftovers == [SyncRun.Leftover(placeholder: "$UID", hopIndex: 2)])
        #expect(run.mappings.isEmpty)
        #expect(SyncPresentation.verdicts(for: run).contains { $0.contains("$UID") && $0.contains("match is lost") })
    }

    /// `uid=0` is a partner saying "no id" (no cookie, or an opt-out) — never a mapping.
    @Test func aSentinelIDIsNoMapping() async throws {
        let transport = ScriptedTransport()
        chain(transport, setuidURL: "https://ssp.example/setuid?bidder=dsp&uid=0")
        let (model, _) = model(transport, device: try device("pixel-8"))

        await model.run()?.value

        let run = try #require(model.lastRun)
        #expect(run.mappings.isEmpty)
        #expect(SyncPresentation.verdicts(for: run).contains { $0.contains("uid=0") && $0.contains("no id") })
    }

    /// On the iPhone (Safari) the same chain stores no third-party cookie: the verdict names the browser.
    @Test func webKitBlockingIsExplained() async throws {
        let transport = ScriptedTransport()
        chain(transport)
        let (model, _) = model(transport)

        await model.run()?.value

        let run = try #require(model.lastRun)
        #expect(model.session.jar.cookies.isEmpty)
        #expect(SyncPresentation.verdicts(for: run).contains { $0.contains(SyncBrowser.safari.title) && $0.contains("blocks third-party cookies") })
    }

    @Test func runAgainReusesTheCookiesAndClearEmptiesTheJar() async throws {
        let transport = ScriptedTransport()
        chain(transport)
        let (model, _) = model(transport, device: try device("pixel-8"))

        await model.run()?.value
        await model.run()?.value

        #expect(model.runCount == 2)
        #expect(transport.requests[4].headers["Cookie"] == "uid=abc123")
        model.clearCookies()
        #expect(model.session.jar.cookies.isEmpty)
    }

    /// A jar belongs to one browser: changing the browser starts a fresh one, and says so.
    @Test func changingTheBrowserClearsTheJar() async throws {
        let transport = ScriptedTransport()
        chain(transport)
        let (model, _) = model(transport, device: try device("pixel-8"))
        await model.run()?.value
        #expect(!model.session.jar.cookies.isEmpty)

        model.browser = .firefox

        #expect(model.session.jar.cookies.isEmpty)
        #expect(model.jarNote != nil)
        #expect(model.browserOverride == .firefox)
        model.browser = .chrome
        #expect(model.browserOverride == nil, "the device's own browser is no override")
    }

    /// A run that fails shows what happened before it failed, never the previous run's success.
    @Test func aFailedRunShowsItsOwnPartialChain() async throws {
        let transport = ScriptedTransport()
        chain(transport)
        let (model, _) = model(transport, device: try device("pixel-8"))
        await model.run()?.value
        #expect(model.lastRun?.mappings.isEmpty == false)
        transport.answer(setuid, .init(status: 0, delay: nil))
        let failing = ScriptedTransport()
        failing.answer(syncStartExpanded, .init(status: 302, headers: ["Location": dspPixel]))
        let (broken, _) = self.model(failing, device: try device("pixel-8"))

        await broken.run()?.value

        let run = try #require(broken.lastRun)
        #expect(run.failure != nil)
        #expect(run.mappings.isEmpty)
        #expect(run.chain.count >= 2)
        #expect(SyncPresentation.verdicts(for: run).first?.contains("failed") == true)
    }

    @Test func cancellingStopsTheRun() async throws {
        let transport = ScriptedTransport()
        transport.answer(syncStartExpanded, .init(status: 200, delay: .seconds(5)))
        let (model, _) = model(transport)
        let running = model.run()
        for _ in 0..<2_000 where transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        model.cancel()
        await running?.value
        #expect(!model.isRunning)
        #expect(model.problem == "Cancelled")
        #expect(model.lastRun == nil)
    }

    @Test func aStartURLThatIsNotHTTPIsRefused() async throws {
        let (model, target) = model(ScriptedTransport())
        model.startURL = "javascript:alert(1)"
        #expect(model.run() == nil)
        #expect(model.problem != nil)
        #expect(target.monitor.liveEntries.isEmpty)
    }

    @Test func offlineRunsNothing() async throws {
        let transport = ScriptedTransport()
        let (model, target) = model(transport)
        target.monitor.offline = true

        await model.run()?.value

        #expect(model.problem?.contains("Offline") == true)
        #expect(transport.requests.isEmpty)
    }
}

@Suite("Sync: presentation")
struct SyncPresentationTests {
    private let cookie = StoredCookie(name: "uid", value: "abc123", domain: "dsp.example", hostOnly: false, path: "/",
                                      expires: Date(timeIntervalSince1970: 1_800_003_600), secure: true, httpOnly: false, sameSite: .none,
                                      partitionSite: nil, created: Date(timeIntervalSince1970: 1_800_000_000))

    @Test func everyRejectionAndWithholdingIsExplained() {
        let rejections: [CookieRejection] = [.malformed, .tooLarge, .secureFromInsecureOrigin, .sameSiteNoneWithoutSecure, .partitionedWithoutSecure,
                                             .prefix("__Host-"), .publicSuffix("co.uk"), .domainMismatch("x.example"), .thirdPartyBlocked,
                                             .sameSiteCrossSite(.lax)]
        #expect(rejections.allSatisfy { !SyncPresentation.explain($0).isEmpty })
        #expect(Set(rejections.map(SyncPresentation.explain)).count == rejections.count)
        let withheld: [CookieWithheld] = [.thirdPartyBlocked, .sameSite(.lax), .secureOnly, .partitionedElsewhere]
        #expect(Set(withheld.map(SyncPresentation.explain)).count == withheld.count)
    }

    @Test func aStoredCookieReadsWithItsAttributes() {
        let line = SyncPresentation.describe(cookie, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(line.contains("uid=abc123"))
        #expect(line.contains("Domain=dsp.example"))
        #expect(line.contains("Secure"))
        #expect(line.contains("SameSite=None"))
        #expect(line.contains("1 h") || line.contains("hour"))
    }

    @Test func policiesHaveNames() {
        #expect(CookiePolicy.allCases.allSatisfy { !SyncPresentation.title(for: $0).isEmpty })
    }
}

import AppKit
import SwiftUI

@MainActor
@Suite("Sync: pane", .serialized)
struct SyncPaneTests {
    @Test func theTabDrawsBeforeAndAfterARun() async throws {
        let transport = ScriptedTransport()
        chain(transport)
        let target = SyncTarget(monitor: NetworkMonitor(transport: transport, publishInterval: .zero))
        let model = SyncModel(target: target)
        model.startURL = syncStart
        model.consent = SyncConsent(gdprApplies: true, tcString: "CPtc")
        let harness = WindowHarness(SyncPane(sync: model), size: CGSize(width: 600, height: 760))
        defer { harness.close() }
        try await Task.sleep(for: .milliseconds(100))
        await model.run()?.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.lastRun != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CCINN_CLIENT_SNAPSHOTS"] != nil), arguments: ["pixel-8", "iphone-18-pro"])
    func snapshot(deviceID: String) async throws {
        let transport = ScriptedTransport()
        chain(transport)
        let target = SyncTarget(monitor: NetworkMonitor(transport: transport, publishInterval: .zero), device: try #require(DeviceCatalog.device(id: deviceID)))
        let model = SyncModel(target: target)
        model.startURL = syncStart
        model.consent = SyncConsent(gdprApplies: true, tcString: "CPtc")
        let harness = WindowHarness(SyncPane(sync: model).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 620, height: 820))
        harness.window.appearance = NSAppearance(named: .aqua)
        defer { harness.close() }
        await model.run()?.value
        await model.run()?.value
        try await Task.sleep(for: .milliseconds(500))
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CCINN_CLIENT_SNAPSHOTS"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = harness.hosting
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("sync-\(deviceID).png"))
    }
}
