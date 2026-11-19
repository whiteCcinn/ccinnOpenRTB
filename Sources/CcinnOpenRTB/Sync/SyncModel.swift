import CcinnOpenRTBKit
import Foundation
import Observation
import RTBKit

/// What the Sync tab needs from the window: its network gate and its simulated device (User-Agent, browser).
@MainActor
protocol SyncTargetProviding: AnyObject {
    var monitor: NetworkMonitor { get }
    var device: DeviceProfile { get }
}

extension AdSession: SyncTargetProviding {}

/// One cookie-sync run and what it shows: the chain with every hop's cookies, the ids passed along, and the placeholders
/// a partner left unsubstituted.
struct SyncRun: Sendable, Equatable {
    struct IDMapping: Sendable, Hashable {
        /// The partner named in the same URL (`bidder`, `partner` …), when there is one.
        var partner: String?
        var id: String
        var parameter: String
        var hopIndex: Int
    }

    struct Leftover: Sendable, Hashable {
        var placeholder: String
        var hopIndex: Int
    }

    var startURL: String
    var replacedMacros: [String]
    var unknownMacros: [String]
    var response: ComposedResponse
    var ranAt: Date
    var policy: CookiePolicy
    var topLevelSite: CookieSite

    var mappings: [IDMapping] {
        response.chain.enumerated().flatMap { index, hop -> [IDMapping] in
            let found = SyncURL.mappingParameters(in: hop.url)
            return found.ids.map { IDMapping(partner: found.partners.first?.value, id: $0.value, parameter: $0.name, hopIndex: index) }
        }
    }

    var leftovers: [Leftover] {
        response.chain.enumerated().flatMap { index, hop in SyncURL.ownPlaceholders(in: hop.url).map { Leftover(placeholder: $0, hopIndex: index) } }
    }

    var decisions: [CookieDecision] { response.chain.flatMap { $0.cookies?.decisions ?? [] } }
}

/// The Sync tab of one main window: a cookie-sync chain run from a start URL on a publisher page, as the device's browser
/// would — consent macros filled, every redirect followed, the window's cookie jar read and filled on every hop.
///
/// - The jar (`session`) belongs to the tab and lives in memory: Run Again shows whether the mapping is stable; Clear
///   Cookies starts over. It is never the Mac's cookies.
/// - The browser policy follows the device (WebKit blocks third-party cookies on Apple devices) unless overridden.
@MainActor
@Observable
final class SyncModel {
    var startURL = ""
    /// The page the sync runs on (its site decides what is third party; its origin is the Referer).
    var publisherURL = "https://news.example/"
    var consent = SyncConsent()
    /// A policy chosen by hand; `nil` follows the device.
    var policyOverride: CookiePolicy?
    private(set) var session: CookieSession
    private(set) var lastRun: SyncRun?
    private(set) var runCount = 0
    private(set) var isRunning = false
    private(set) var problem: String?

    @ObservationIgnored private let target: any SyncTargetProviding
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(target: any SyncTargetProviding, now: @escaping @MainActor () -> Date = { Date() }) {
        self.target = target
        self.now = now
        let site = CookieSite(url: URL(string: "https://news.example/")!)!
        session = CookieSession(context: CookieContext(topLevelSite: site, policy: Self.defaultPolicy(for: target.device)))
    }

    /// The browser's third-party cookie policy for `device`: WebKit's (blocked) on Apple's operating systems, Chrome's
    /// elsewhere.
    static func defaultPolicy(for device: DeviceProfile) -> CookiePolicy {
        ["iOS", "iPadOS", "tvOS"].contains(device.os) ? .blockThirdParty : .allowThirdParty
    }

    var policy: CookiePolicy {
        get { policyOverride ?? Self.defaultPolicy(for: target.device) }
        set { policyOverride = newValue == Self.defaultPolicy(for: target.device) ? nil : newValue }
    }

    var device: DeviceProfile { target.device }

    // MARK: Run

    /// Runs the chain. Returns the task (tests await it); `nil` when it cannot start (the reason is in `problem`).
    @discardableResult
    func run() -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        let expanded = SyncURL.expandConsentMacros(in: startURL.trimmingCharacters(in: .whitespacesAndNewlines), consent: consent)
        let scheme = URLText.scheme(expanded.url)
        guard scheme == "http" || scheme == "https", URLText.requestURL(expanded.url)?.host?.isEmpty == false else {
            problem = "The start URL must be an http(s) URL with a host: the SSP’s sync endpoint or the partner’s pixel."
            return nil
        }
        guard let publisher = URLText.requestURL(publisherURL.trimmingCharacters(in: .whitespacesAndNewlines)), let site = CookieSite(url: publisher),
              let host = publisher.host else {
            problem = "The publisher page must be an http(s) URL: its site decides which cookies are third party."
            return nil
        }
        let policy = policy
        session.context = CookieContext(topLevelSite: site, policy: policy)
        // A pixel on the page: an image request, with the page's origin as Referer (strict-origin-when-cross-origin).
        let origin = "\(publisher.scheme ?? "https")://\(host)\(publisher.port.map { ":\($0)" } ?? "")/"
        let request = ComposedRequest(url: expanded.url, method: "GET",
                                      headers: ["Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8", "Referer": origin],
                                      redirects: .all, purpose: .userSync, cookies: session)
        generation &+= 1
        let token = generation
        let monitor = target.monitor
        let userAgent = target.device.userAgent
        isRunning = true
        problem = nil
        let task = Task { [weak self] in
            do {
                let response = try await monitor.send(request, userAgent: userAgent)
                guard let self, token == self.generation else { return }
                self.lastRun = SyncRun(startURL: expanded.url, replacedMacros: expanded.replaced, unknownMacros: expanded.unknown, response: response,
                                       ranAt: self.now(), policy: policy, topLevelSite: site)
                self.runCount += 1
            } catch {
                guard let self, token == self.generation else { return }
                self.problem = ClientModel.message(for: error)
            }
            if let self, token == self.generation { self.isRunning = false }
        }
        runTask = task
        return task
    }

    func cancel() {
        guard isRunning else { return }
        generation &+= 1
        runTask?.cancel()
        isRunning = false
        problem = "Cancelled"
    }

    func clearCookies() { session.clear() }
}
