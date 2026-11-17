import Foundation

/// Native 1.0–1.2 (and AdCOM native) document rules. Field-level problems (missing `url`, wrong types) are reported while
/// decoding; this pass checks the document as a whole and against the request.
enum NativeValidator {
    static let validEvents = 1...4
    static let validMethods = 1...2

    static func validate(_ decoded: DecodedNative, hints: NativeRequestHints?, log: inout IssueLog) {
        let ad = decoded.ad
        let body = decoded.bodyPointer
        let assetsKey = decoded.dialect == .adcom ? "asset" : "assets"

        // Assets and link.
        if ad.assets.isEmpty, ad.assetsURL == nil, ad.dcoURL == nil {
            log.error("native.assets.missing", "The response has no assets (and no `assetsurl` / `dcourl`).", at: body.appending(assetsKey))
        }
        if !decoded.hasLink {
            if decoded.dialect == .native {
                log.error("native.link.missing", "`link` is required: it is the default destination of the ad.", at: body.appending("link"))
            } else if !ad.assets.contains(where: { $0.link != nil }) {
                log.warning("native.link.missing", "Neither the native object nor any asset has a `link`: the ad cannot be clicked.",
                            at: body.appending("link"))
            }
        }

        // Asset ids.
        var seen: Set<Int> = []
        for (asset, pointer) in zip(ad.assets, decoded.assetPointers) where asset.id >= 0 {
            if !seen.insert(asset.id).inserted {
                log.warning("native.asset.id.duplicate", "Asset id \(asset.id) is used more than once.", at: pointer.appending("id"))
            }
        }

        // Against the request.
        if let hints {
            validateAgainstRequest(ad, pointers: decoded.assetPointers, hints: hints, assetsPointer: body.appending(assetsKey), log: &log)
        }

        // Event trackers.
        for (tracker, pointer) in zip(ad.eventTrackers, decoded.eventTrackerPointers) {
            if !validEvents.contains(tracker.event), tracker.event < 500 {
                log.warning("native.eventtracker.event.invalid",
                            "Event type \(tracker.event) is not 1 (impression), 2 (viewable-mrc50), 3 (viewable-mrc100), 4 (viewable-video50) or 500+.",
                            at: pointer.appending("event"))
            }
            if !validMethods.contains(tracker.method), tracker.method < 500 {
                log.warning("native.eventtracker.method.invalid", "Method \(tracker.method) is not 1 (image pixel), 2 (JavaScript) or 500+.",
                            at: pointer.appending("method"))
            }
        }

        if decoded.dialect == .native { validateVersion(decoded, log: &log) }
    }

    private static func validateAgainstRequest(_ ad: NativeAd, pointers: [JSONPointer], hints: NativeRequestHints, assetsPointer: JSONPointer,
                                               log: inout IssueLog) {
        let responseIDs = Set(ad.assets.map(\.id))
        for id in hints.required.sorted() where !responseIDs.contains(id) {
            log.error("native.asset.required.missing", "The request marks asset \(id) as required, but the response does not include it.",
                      at: assetsPointer)
        }
        guard !hints.assets.isEmpty else { return }
        for (asset, pointer) in zip(ad.assets, pointers) where asset.id >= 0 {
            guard let hint = hints.assets[asset.id] else {
                log.warning("native.asset.id.unknown", "Asset id \(asset.id) is not in the Native request.", at: pointer.appending("id"))
                continue
            }
            switch (asset.content, hint) {
            case let (.title(text), .title(maxLength)):
                if let maxLength, maxLength > 0, text.count > maxLength {
                    log.warning("native.title.length", "The title has \(text.count) characters; the request allows \(maxLength).",
                                at: pointer.appending("title").appending("text"))
                }
            case let (.data(value, _, _), .data(_, maxLength)):
                if let maxLength, maxLength > 0, value.count > maxLength {
                    log.warning("native.data.length", "The data value has \(value.count) characters; the request allows \(maxLength).",
                                at: pointer.appending("data").appending("value"))
                }
            case let (.image(_, _, _, responseType), .image(requestType, _, _)):
                if let responseType, let requestType, responseType != requestType {
                    log.warning("native.img.type.mismatch", "The request asks for image type \(requestType.rawValue), the response has \(responseType.rawValue).",
                                at: pointer)
                }
            case (.video, .video):
                break
            default:
                log.warning("native.asset.type.mismatch", "Asset \(asset.id) is a \(kindName(asset.content)) but the request declares a \(kindName(hint)).",
                            at: pointer)
            }
        }
    }

    private static func validateVersion(_ decoded: DecodedNative, log: inout IssueLog) {
        let body = decoded.bodyPointer
        guard let version = decoded.declaredVersion else { return }
        if version < SpecVersion(major: 1, minor: 2), !decoded.ad.wrapped {
            log.info("native.wrapper.missing", "Native \(version.major).\(version.minor) responses use the `{\"native\": …}` root object.", at: .root)
        }
        if version < SpecVersion(major: 1, minor: 2) {
            if decoded.usesEventTrackers {
                log.info("native.eventtrackers.version", "`eventtrackers` was added in Native 1.2.", at: body.appending("eventtrackers"))
            }
            if decoded.usesPrivacy {
                log.info("native.privacy.version", "`privacy` was added in Native 1.2.", at: body.appending("privacy"))
            }
        } else {
            if decoded.usesImpTrackers {
                log.info("native.imptrackers.deprecated", "`imptrackers` is deprecated in Native 1.2; use `eventtrackers` (event 1, method 1).",
                         at: body.appending("imptrackers"))
            }
            if decoded.usesJSTracker {
                log.info("native.jstracker.deprecated", "`jstracker` is deprecated in Native 1.2; use `eventtrackers` (method 2).",
                         at: body.appending("jstracker"))
            }
        }
    }

    /// URLs the device loads: trackers (impression, event and click trackers) and creative assets (images).
    static func clientSideURLs(_ decoded: DecodedNative) -> [(url: String, isTracker: Bool, pointer: JSONPointer)] {
        let ad = decoded.ad
        let body = decoded.bodyPointer
        let clickKey = decoded.dialect == .adcom ? "trkr" : "clicktrackers"
        var urls: [(url: String, isTracker: Bool, pointer: JSONPointer)] = []
        for (index, url) in ad.impressionTrackers.enumerated() {
            urls.append((url, true, body.appending("imptrackers").appending(index)))
        }
        for (tracker, pointer) in zip(ad.eventTrackers, decoded.eventTrackerPointers) {
            urls.append((tracker.url, true, pointer.appending("url")))
        }
        for (index, url) in ad.link.clickTrackers.enumerated() {
            urls.append((url, true, body.appending("link").appending(clickKey).appending(index)))
        }
        for (asset, pointer) in zip(ad.assets, decoded.assetPointers) {
            if case let .image(url, _, _, _) = asset.content { urls.append((url, false, pointer)) }
            for (index, url) in (asset.link?.clickTrackers ?? []).enumerated() {
                urls.append((url, true, pointer.appending("link").appending(clickKey).appending(index)))
            }
        }
        return urls
    }

    private static func kindName(_ content: NativeAsset.Content) -> String {
        switch content {
        case .title: "title"
        case .image: "image"
        case .video: "video"
        case .data: "data"
        }
    }

    private static func kindName(_ hint: NativeRequestHints.AssetHint) -> String {
        switch hint {
        case .title: "title"
        case .image: "image"
        case .video: "video"
        case .data: "data"
        }
    }
}
