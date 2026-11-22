import Foundation
import os
import RTBKit
import Testing
@testable import CcinnOpenRTBKit

extension Duration {
    /// A fake answer held until the test cancels it. The outcome must depend on the cancellation alone: a short delay
    /// (it was 5 s) races the cancel on a starved 3-core CI runner and lets the response through. This only guards
    /// against a hang if cancellation breaks.
    static let heldUntilCancelled = Duration.seconds(60)
}

/// A clock tests move by hand.
final class ManualClock: NetworkClock {
    private let current: OSAllocatedUnfairLock<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = OSAllocatedUnfairLock(initialState: start)
    }

    func now() -> Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Serves canned responses by URL and records every request. Advances the clock by `latency` per request.
final class FakeTransport: HTTPTransport {
    struct Route: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
        var delay: Duration?
        /// Runs (on the main actor) before the response is returned.
        var beforeResponding: (@MainActor @Sendable () -> Void)?
    }

    private struct State {
        var routes: [String: Route] = [:]
        var requests: [HTTPRequest] = []
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let clock: ManualClock?
    private let latency: TimeInterval

    init(clock: ManualClock? = nil, latency: TimeInterval = 0.025) {
        self.clock = clock
        self.latency = latency
    }

    func respond(_ url: String, status: Int = 200, headers: [String: String] = [:], body: String = "", delay: Duration? = nil,
                 beforeResponding: (@MainActor @Sendable () -> Void)? = nil) {
        respond(url, status: status, headers: headers, data: Data(body.utf8), delay: delay, beforeResponding: beforeResponding)
    }

    func respond(_ url: String, status: Int = 200, headers: [String: String] = [:], data: Data, delay: Duration? = nil,
                 beforeResponding: (@MainActor @Sendable () -> Void)? = nil) {
        state.withLockUnchecked { $0.routes[url] = Route(status: status, headers: headers, body: data, delay: delay, beforeResponding: beforeResponding) }
    }

    func redirect(_ url: String, to location: String, status: Int = 302) {
        respond(url, status: status, headers: ["Location": location])
    }

    var requests: [HTTPRequest] { state.withLockUnchecked { $0.requests } }
    var requestedURLs: [String] { requests.map(\.url.absoluteString) }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        let route = state.withLockUnchecked { state -> Route? in
            state.requests.append(request)
            return state.routes[request.url.absoluteString]
        }
        if let delay = route?.delay { try await Task.sleep(for: delay) }
        if let hook = route?.beforeResponding { await hook() }
        clock?.advance(by: latency)
        guard let route else { throw URLError(.cannotFindHost) }
        let truncated = route.body.count > request.maxBodyBytes
        return HTTPResponse(status: route.status, headers: route.headers, body: route.body.prefix(request.maxBodyBytes), truncated: truncated,
                            timings: HTTPTimings(dns: 1, connect: 2, ssl: 1, send: 0.5, wait: latency * 1000 - 3.5, receive: 0))
    }
}

/// Fails the test if anything tries to send. Simulated-mode tests use it to prove nothing leaves the machine.
final class FailingTransport: HTTPTransport {
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    var callCount: Int { calls.withLock { $0 } }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        calls.withLock { $0 += 1 }
        Issue.record("The transport was called for \(request.url.absoluteString) — nothing may be sent here")
        throw URLError(.notConnectedToInternet)
    }
}

/// Serves sample assets from small files without generating media.
///
/// Owns its temporary directory: it is removed when the last reference goes away (for `makeMonitor`, with the
/// monitor), so a test needs no cleanup of its own and leaves nothing behind.
final class FakeSamples: SampleMediaProviding {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-fake-samples-\(UUID().uuidString)")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func fileURL(for asset: SampleAsset) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(asset.fileName)
        try Data("sample:\(asset.fileName)".utf8).write(to: file)
        return file
    }
}

@MainActor
func makeMonitor(transport: any HTTPTransport, clock: ManualClock = ManualClock(), capacity: Int = NetworkMonitor.defaultCapacity) -> NetworkMonitor {
    NetworkMonitor(transport: transport, clock: clock, samples: FakeSamples(), publishInterval: .zero, capacity: capacity)
}

func tracker(_ category: TrackerCategory, _ url: String, trigger: String? = nil, parentID: UUID? = nil, isScript: Bool = false) -> TrackerRequest {
    TrackerRequest(parentID: parentID, category: category, trigger: trigger ?? category.rawValue, source: "bid 0.0", template: url, url: url,
                   isScript: isScript)
}

let deviceUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
