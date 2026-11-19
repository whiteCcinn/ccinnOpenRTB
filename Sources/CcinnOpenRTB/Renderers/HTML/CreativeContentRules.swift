import Foundation
import WebKit

/// Compiled `WKContentRuleList`s for creative web views, compiled once per process and shared.
///
/// - `blockNetwork` (every mode but Real): blocks every http(s) and ws(s) load except the creative document itself
///   (`loadHTMLString` with `CreativeWebController.baseURL`). The attempts the instrumentation sees (elements, `fetch`,
///   XHR, `sendBeacon`, WebSocket, WebRTC) are reported as `blocked`; loads from CSS, `EventSource`, `<a ping>` and
///   workers are blocked without a report.
/// - `mraidJS` (always): a `<script src="mraid.js">` is served by the container (the shim is already injected), as SDKs do;
///   the request is dropped instead of going to the network.
@MainActor
enum CreativeContentRules {
    enum RuleError: Error, LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(message): message
            }
        }
    }

    static let blockNetworkIdentifier = "ccinn.creative.block-network.v1"
    static let mraidJSIdentifier = "ccinn.creative.mraid-js.v1"

    static var blockNetworkSource: String {
        let base = "^" + NSRegularExpression.escapedPattern(for: CreativeWebController.baseURL.absoluteString) + "$"
        return """
        [
          {"trigger": {"url-filter": "^[hH][tT][tT][pP][sS]?:"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^[wW][sS][sS]?:"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": \(JSLiteral.string(base))}, "action": {"type": "ignore-previous-rules"}}
        ]
        """
    }

    static let mraidJSSource = """
    [{"trigger": {"url-filter": "/mraid\\\\.js"}, "action": {"type": "block"}}]
    """

    private static var compiled: [String: WKContentRuleList] = [:]
    private static var inFlight: [String: Task<WKContentRuleList, any Error>] = [:]

    static let prebidPageIdentifier = "ccinn.prebid.page.v2"

    /// The Prebid page: every load is blocked but local ones (`blob:` — Prebid.js's scripts, handed over by the shim —
    /// `data:` and `about:`). The page itself is a simulated response, never fetched; its network APIs are shimmed to go
    /// through the monitor, and anything the shim does not cover (a stylesheet, an image in markup) fails closed here.
    static let prebidPageSource = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    static func prebidPage() async throws -> WKContentRuleList {
        try await list(identifier: prebidPageIdentifier, source: prebidPageSource)
    }

    static func blockNetwork() async throws -> WKContentRuleList {
        try await list(identifier: blockNetworkIdentifier, source: blockNetworkSource)
    }

    static func mraidJS() async throws -> WKContentRuleList {
        try await list(identifier: mraidJSIdentifier, source: mraidJSSource)
    }

    private static func list(identifier: String, source: String) async throws -> WKContentRuleList {
        if let ready = compiled[identifier] { return ready }
        if let running = inFlight[identifier] { return try await running.value }
        let task = Task<WKContentRuleList, any Error> { try await compile(identifier: identifier, source: source) }
        inFlight[identifier] = task
        defer { inFlight[identifier] = nil }
        let list = try await task.value
        compiled[identifier] = list
        return list
    }

    private static func compile(identifier: String, source: String) async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else { throw RuleError.unavailable("No content rule list store") }
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? RuleError.unavailable("Content rules did not compile"))
                }
            }
        }
    }
}
