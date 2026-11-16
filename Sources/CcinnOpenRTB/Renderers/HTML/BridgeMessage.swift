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
}

/// One message posted by the injected scripts (`window.webkit.messageHandlers.ccinn`). Decoding is defensive: the page is
/// untrusted, so anything malformed is dropped and strings are length-capped.
enum BridgeMessage: Equatable, Sendable {
    /// An MRAID call: the command to act on and a readable description of the call for the log.
    case mraid(MRAIDCommand, description: String)
    /// The shim changed state (`loading` / `default` / `expanded` / `resized` / `hidden`).
    case mraidState(String, customClose: Bool)
    /// A request the creative made or tried to make.
    case network(url: String, kind: String)
    /// A user gesture (pointer or key) inside the creative; a navigation shortly after it is a click.
    case gesture
    /// `console.*` / `window.onerror` output of the creative.
    case console(level: String, message: String)

    static let handlerName = "ccinn"
    static let maxStringLength = 16 * 1024

    static func decode(_ body: Any) -> BridgeMessage? {
        guard let object = body as? [String: Any], let channel = object["channel"] as? String else { return nil }
        switch channel {
        case "mraid":
            guard let name = string(object["name"]) else { return nil }
            let description = string(object["description"]) ?? "\(name)()"
            return .mraid(command(name: name, args: object["args"] as? [String: Any] ?? [:]), description: description)
        case "state":
            guard let state = string(object["state"]), validStates.contains(state) else { return nil }
            return .mraidState(state, customClose: object["customClose"] as? Bool ?? false)
        case "net":
            guard let url = string(object["url"]), !url.isEmpty else { return nil }
            return .network(url: url, kind: string(object["kind"]) ?? "resource")
        case "gesture":
            return .gesture
        case "console":
            return .console(level: string(object["level"]) ?? "log", message: string(object["message"]) ?? "")
        default:
            return nil
        }
    }

    static let validStates: Set<String> = ["loading", "default", "expanded", "resized", "hidden"]

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
}
