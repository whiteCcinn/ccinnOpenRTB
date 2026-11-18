import Foundation

/// Reads the asset declarations of a Native request: OpenRTB 2.x `imp.native.request` (Native 1.0 wrapped or 1.1+
/// unwrapped) or AdCOM `nativefmt`. Only what resolves response asset types is kept (design D5).
enum NativeRequestReader {
    /// `request` is the JSON string of `imp.native.request`.
    static func hints(fromRequestString request: String, at pointer: JSONPointer, log: inout IssueLog) -> NativeRequestHints? {
        let value: JSONValue
        do {
            value = try JSONValue.parse(request)
        } catch {
            if !log.nestedTooDeeply(error, code: "request.native.depth", severity: .warning, in: pointer, outcome: "The Native request was ignored.") {
                log.warning("request.native.invalid", "The Native request is not a JSON object.", at: pointer)
            }
            return nil
        }
        guard case let .object(members) = value else {
            log.warning("request.native.invalid", "The Native request is not a JSON object.", at: pointer)
            return nil
        }
        return hints(from: JSONObjectReader(members, at: pointer, domain: "request"), log: &log)
    }

    /// `reader` is the Native request object (wrapped or not) or an AdCOM `nativefmt`.
    static func hints(from reader: JSONObjectReader, log: inout IssueLog) -> NativeRequestHints {
        let body = reader.object("native", log: &log) ?? reader
        var hints = NativeRequestHints(version: body.version("ver", log: &log))
        let assets = body.objects("assets", log: &log) ?? body.objects("asset", log: &log) ?? []
        for (_, asset) in assets {
            guard let id = asset.int("id", log: &log) else { continue }
            if asset.flag("required", log: &log) == true || asset.flag("req", log: &log) == true { hints.required.insert(id) }
            if let title = asset.object("title", log: &log) {
                hints.assets[id] = .title(maxLength: title.int("len", log: &log))
            } else if let image = asset.object("img", log: &log) ?? asset.object("image", log: &log) {
                hints.assets[id] = .image(type: image.int("type", log: &log).flatMap(NativeImageType.init(rawValue:)),
                                          width: image.int("w", log: &log) ?? image.int("wmin", log: &log),
                                          height: image.int("h", log: &log) ?? image.int("hmin", log: &log))
            } else if asset.has("video") {
                hints.assets[id] = .video
            } else if let data = asset.object("data", log: &log) {
                hints.assets[id] = .data(type: data.int("type", log: &log).flatMap(NativeDataType.init(rawValue:)),
                                         maxLength: data.int("len", log: &log))
            }
        }
        return hints
    }
}
