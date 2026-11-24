import Foundation

/// A command the creative issued through `window.mraid` that the container acts on.
enum MRAIDCommand: Equatable, Sendable {
    case open(url: String)
    case close
    case unload
    case expand(url: String?)
    case resize
    case useCustomClose(Bool)
    case playVideo(url: String)
    /// Any other call (getters, setters, listeners, unsupported features): logged only.
    case other

    /// The trigger of `playVideo`'s navigation: the SDK's own video player plays it — recorded, not a click-through that
    /// opens another screen.
    static let playVideoTrigger = "mraid.playVideo (native player)"
}

/// What the network instrumentation saw the creative do.
enum CreativeNetworkMessage: Equatable, Sendable {
    /// A request started (fetch, XHR, beacon, WebSocket, an element's `src` / `href`). `rid` is unique per document.
    case start(rid: String, url: String, kind: String)
    /// The outcome of a started request, when the page can observe it.
    case end(rid: String, status: Int?, bytes: Int?, error: String?)
    /// Resource timing of a load no hook saw (CSS backgrounds, fonts).
    case timing(url: String, kind: String, status: Int?, bytes: Int?)
    /// The page stopped reporting (too many requests).
    case overflow
}

/// One message posted by the injected scripts (`window.webkit.messageHandlers.ccinn`). Decoding is defensive: the page
/// is untrusted, so anything malformed is dropped, strings are length-capped and numbers bounded. The controller accepts
/// only messages carrying its per-load secret (`nonceKey`); user gestures are seen natively, never reported by the page.
enum BridgeMessage: Equatable, Sendable {
    /// An MRAID call: the command to act on and a readable description of the call for the log.
    case mraid(MRAIDCommand, description: String)
    /// An MRAID `error` event the shim fired (bad arguments, unsupported feature, wrong state).
    case mraidError(message: String, action: String)
    /// The shim changed state (`loading` / `default` / `expanded` / `resized` / `hidden`) or custom close, with the ad's
    /// current size.
    case mraidState(String, customClose: Bool, size: MRAIDSize?)
    /// A request the creative made or tried to make.
    case network(CreativeNetworkMessage)
    /// `window.open(url)` (overridden: never opens a window).
    case windowOpen(url: String)
    /// `console.*` / `window.onerror` output of the creative.
    case console(level: String, message: String)
    /// A gesture of the emulated finger (touch devices), reported when it ends.
    case touch(TouchGesture)

    static let handlerName = "ccinn"
    /// The key of the per-load secret every message of the injected scripts carries (see `CreativeWebController`).
    static let nonceKey = "n"
    static let maxStringLength = 16 * 1024

    static func decode(_ body: Any) -> BridgeMessage? {
        guard let object = body as? [String: Any], let channel = object["channel"] as? String else { return nil }
        switch channel {
        case "mraid":
            guard let name = string(object["name"]) else { return nil }
            let description = string(object["description"]) ?? "\(name)()"
            return .mraid(command(name: name, args: object["args"] as? [String: Any] ?? [:]), description: description)
        case "mraidError":
            return .mraidError(message: string(object["message"]) ?? "error", action: string(object["action"]) ?? "")
        case "state":
            guard let state = string(object["state"]), validStates.contains(state) else { return nil }
            var size: MRAIDSize?
            if let width = dimension(object["width"]), let height = dimension(object["height"]) { size = MRAIDSize(width: width, height: height) }
            return .mraidState(state, customClose: object["customClose"] as? Bool ?? false, size: size)
        case "net":
            return network(object).map(BridgeMessage.network)
        case "open":
            guard let url = string(object["url"]), !url.isEmpty else { return nil }
            return .windowOpen(url: url)
        case "console":
            let level = string(object["level"]).flatMap { consoleLevels.contains($0) ? $0 : nil } ?? "log"
            return .console(level: level, message: string(object["message"]) ?? "")
        case "touch":
            return TouchGesture.decode(object).map(BridgeMessage.touch)
        default:
            return nil
        }
    }

    static let validStates: Set<String> = ["loading", "default", "expanded", "resized", "hidden"]
    static let consoleLevels: Set<String> = ["log", "info", "warn", "error", "debug"]

    private static func network(_ object: [String: Any]) -> CreativeNetworkMessage? {
        switch string(object["phase"]) {
        case "start":
            guard let rid = string(object["rid"]), let url = string(object["url"]), !url.isEmpty else { return nil }
            return .start(rid: rid, url: url, kind: string(object["kind"]) ?? "resource")
        case "end":
            guard let rid = string(object["rid"]) else { return nil }
            return .end(rid: rid, status: count(object["status"]), bytes: count(object["bytes"]), error: string(object["error"]))
        case "timing":
            guard let url = string(object["url"]), !url.isEmpty else { return nil }
            return .timing(url: url, kind: string(object["kind"]) ?? "resource", status: count(object["status"]), bytes: count(object["bytes"]))
        case "overflow":
            return .overflow
        default:
            return nil
        }
    }

    private static func command(name: String, args: [String: Any]) -> MRAIDCommand {
        switch name {
        case "open":
            guard let url = string(args["url"]), !url.isEmpty else { return .other }
            return .open(url: url)
        case "close": return .close
        case "unload": return .unload
        case "expand": return .expand(url: string(args["url"]).flatMap { $0.isEmpty ? nil : $0 })
        case "resize": return .resize
        case "useCustomClose": return .useCustomClose(args["value"] as? Bool ?? false)
        case "playVideo":
            guard let url = string(args["url"]), !url.isEmpty else { return .other }
            return .playVideo(url: url)
        default: return .other
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return text.count > maxStringLength ? String(text.prefix(maxStringLength)) + "…" : text
    }

    /// A size in points (finite, 0…100,000).
    private static func dimension(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= 100_000 else { return nil }
        return double
    }

    /// A non-negative whole number that fits an `Int` (JS numbers arrive as `NSNumber`; strings and NaN are rejected).
    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= Double(Int32.max) else { return nil }
        return Int(double)
    }
}
