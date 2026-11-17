import Foundation

/// Native 1.0 / 1.1 / 1.2 response parser (design D5). Owner: kit-openrtb.
///
/// Accepts the wrapped (`{"native": …}`) and unwrapped forms, `ver` as a string or a number, and the AdCOM 1.0
/// `display.native` object of OpenRTB 3.0 (`asset[]`, `req`, `image`/`img`, `video.adm`/`curl`, `link.urlfb`/`trkr`).
/// Issue paths are JSON pointers into `json`.
public enum NativeParser {
    public static func parse(_ json: String, hints: NativeRequestHints? = nil) -> (ad: NativeAd?, issues: [ValidationIssue]) {
        let (decoded, issues) = decode(json, hints: hints)
        return (decoded?.ad, issues)
    }

    /// The decoded document with the locations validation needs (used by `InputParser` for secure-impression checks).
    static func decode(_ json: String, hints: NativeRequestHints?) -> (decoded: DecodedNative?, issues: [ValidationIssue]) {
        var log = IssueLog()
        let value: JSONValue
        do {
            value = try JSONValue.parse(json)
        } catch {
            log.error("native.json.invalid", "The Native markup is not valid JSON: \(error).", at: .root)
            return (nil, log.issues)
        }
        guard case let .object(members) = value else {
            log.error("native.json.invalid", "The Native markup must be a JSON object.", at: .root)
            return (nil, log.issues)
        }
        var decoder = NativeDecoder(hints: hints, log: log)
        guard let decoded = decoder.decode(JSONObjectReader(members, at: .root, domain: "native")) else { return (nil, decoder.log.issues) }
        var issues = decoder.log
        NativeValidator.validate(decoded, hints: hints, log: &issues)
        return (decoded, issues.issues)
    }
}

extension NativeAsset {
    /// The VAST of a video asset: inline XML (`vasttag`, AdCOM `adm`) or a tag URL (AdCOM `curl`).
    public var vastSource: VASTSource? {
        guard case let .video(vastTag) = content else { return nil }
        let trimmed = vastTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return MarkupSniffer.isHTTPURL(trimmed) ? .url(trimmed) : .xml(vastTag)
    }
}

/// The decoded ad plus what validation needs to know about the document.
struct DecodedNative {
    enum Dialect {
        /// OpenRTB Native 1.x.
        case native
        /// AdCOM 1.0 `display.native`.
        case adcom
    }

    var ad: NativeAd
    var dialect: Dialect
    var bodyPointer: JSONPointer
    var declaredVersion: SpecVersion?
    var hasLink: Bool
    /// Pointers of the decoded assets, in `ad.assets` order.
    var assetPointers: [JSONPointer]
    /// Pointers of the decoded event trackers, in `ad.eventTrackers` order.
    var eventTrackerPointers: [JSONPointer]
    var usesImpTrackers: Bool
    var usesJSTracker: Bool
    var usesEventTrackers: Bool
    var usesPrivacy: Bool
}

private struct NativeDecoder {
    let hints: NativeRequestHints?
    var log: IssueLog

    init(hints: NativeRequestHints?, log: IssueLog) {
        self.hints = hints
        self.log = log
    }

    mutating func decode(_ root: JSONObjectReader) -> DecodedNative? {
        var body = root
        var wrapped = false
        let wrapperPointer = root.pointer.appending("native")
        switch root.raw("native") {
        case let .object(members)?:
            body = JSONObjectReader(members, at: wrapperPointer, domain: "native")
            wrapped = true
        case let .string(text)?:
            // Double-encoded wrapper: `{"native": "{…}"}`.
            guard let inner = try? JSONValue.parse(text), case let .object(members) = inner else {
                log.error("native.json.invalid", "`native` must be an object.", at: wrapperPointer)
                return nil
            }
            log.warning("native.type.mismatch", "`native` should be an object, found a JSON string holding one.", at: wrapperPointer)
            body = JSONObjectReader(members, at: wrapperPointer, domain: "native")
            wrapped = true
        case .some:
            log.error("native.json.invalid", "`native` must be an object.", at: wrapperPointer)
            return nil
        case nil:
            break
        }

        let dialect: DecodedNative.Dialect = (!body.has("assets") && body.has("asset")) ? .adcom : .native
        let version = body.version("ver", log: &log)
        var ad = NativeAd(version: version, wrapped: wrapped)
        var decoded = DecodedNative(ad: ad, dialect: dialect, bodyPointer: body.pointer, declaredVersion: version.flatMap(SpecVersion.init),
                                    hasLink: false, assetPointers: [], eventTrackerPointers: [], usesImpTrackers: body.has("imptrackers"),
                                    usesJSTracker: body.has("jstracker"), usesEventTrackers: body.has("eventtrackers"),
                                    usesPrivacy: body.has("privacy"))

        let assets = dialect == .adcom ? body.objects("asset", log: &log) : body.objects("assets", log: &log)
        for (index, asset) in assets ?? [] {
            if let decodedAsset = decodeAsset(asset, index: index) {
                ad.assets.append(decodedAsset)
                decoded.assetPointers.append(asset.pointer)
            }
        }
        if let link = body.object("link", log: &log) {
            ad.link = decodeLink(link)
            decoded.hasLink = true
        }
        ad.impressionTrackers = body.strings("imptrackers", log: &log) ?? []
        ad.jsTracker = body.string("jstracker", log: &log)
        for (_, tracker) in body.objects("eventtrackers", log: &log) ?? [] {
            if let eventTracker = decodeEventTracker(tracker) {
                ad.eventTrackers.append(eventTracker)
                decoded.eventTrackerPointers.append(tracker.pointer)
            }
        }
        ad.privacyURL = body.string("privacy", log: &log)
        ad.assetsURL = body.string("assetsurl", log: &log)
        ad.dcoURL = body.string("dcourl", log: &log)
        decoded.ad = ad
        return decoded
    }

    // MARK: Assets

    private mutating func decodeAsset(_ asset: JSONObjectReader, index: Int) -> NativeAsset? {
        let declaredID = asset.int("id", log: &log)
        let id = declaredID ?? -(index + 1)
        let required = asset.flag("required", log: &log) ?? asset.flag("req", log: &log) ?? false
        let link = asset.object("link", log: &log).map { decodeLink($0) }
        let hint = declaredID.flatMap { hints?.assets[$0] }

        let title = asset.object("title", log: &log)
        let image = asset.object("img", log: &log) ?? asset.object("image", log: &log)
        let video = asset.object("video", log: &log)
        let data = asset.object("data", log: &log)
        if [title, image, video, data].compactMap({ $0 }).count > 1 {
            log.warning("native.asset.content.multiple", "An asset carries exactly one of title, img, video or data; the first one is used.",
                        at: asset.pointer)
        }

        let content: NativeAsset.Content
        var typeSource: NativeTypeSource = .response
        if let title {
            let text = title.string("text", log: &log)
            if text == nil { log.error("native.title.text.missing", "A title asset needs `text`.", at: title.pointer.appending("text")) }
            content = .title(text: text ?? "")
        } else if let image {
            let url = image.string("url", log: &log)
            if url == nil { log.error("native.img.url.missing", "An image asset needs `url`.", at: image.pointer.appending("url")) }
            let width = image.int("w", log: &log)
            let height = image.int("h", log: &log)
            var type: NativeImageType?
            if let rawType = image.int("type", log: &log) {
                type = NativeImageType(rawValue: rawType)
                if type == nil, rawType < 500 {
                    log.warning("native.img.type.invalid", "Image type \(rawType) is not 1 (icon), 2 (logo) or 3 (main).",
                                at: image.pointer.appending("type"))
                }
            }
            if type == nil, case let .image(hintType, _, _)? = hint, let hintType {
                type = hintType
                typeSource = .request
            } else if type == nil {
                type = NativeTypeInference.imageType(url: url ?? "", width: width, height: height)
                typeSource = .inferred
            }
            content = .image(url: url ?? "", width: width, height: height, type: type)
        } else if let video {
            let tag = video.string("vasttag", log: &log) ?? video.string("adm", log: &log) ?? video.string("curl", log: &log)
            if tag == nil { log.error("native.video.vasttag.missing", "A video asset needs `vasttag`.", at: video.pointer.appending("vasttag")) }
            content = .video(vastTag: tag ?? "")
        } else if let data {
            let value = data.string("value", log: &log)
            if value == nil { log.error("native.data.value.missing", "A data asset needs `value`.", at: data.pointer.appending("value")) }
            let label = data.string("label", log: &log)
            var type: NativeDataType?
            if let rawType = data.int("type", log: &log) {
                type = NativeDataType(rawValue: rawType)
                if type == nil, rawType < 500 {
                    log.warning("native.data.type.invalid", "Data type \(rawType) is not defined by the Native specification.",
                                at: data.pointer.appending("type"))
                }
            }
            if type == nil, case let .data(hintType, _)? = hint, let hintType {
                type = hintType
                typeSource = .request
            } else if type == nil {
                type = NativeTypeInference.dataType(label: label, value: value ?? "")
                typeSource = type == nil ? .unknown : .inferred
            }
            content = .data(value: value ?? "", label: label, type: type)
        } else {
            log.warning("native.asset.content.missing", "The asset has none of title, img, video or data; it was skipped.", at: asset.pointer)
            return nil
        }
        return NativeAsset(id: id, required: required, content: content, link: link, typeSource: typeSource)
    }

    // MARK: Link and trackers

    private mutating func decodeLink(_ link: JSONObjectReader) -> AdLink {
        let url = link.string("url", log: &log) ?? ""
        let trackers = link.strings("clicktrackers", log: &log) ?? link.strings("trkr", log: &log) ?? []
        let fallback = link.string("fallback", log: &log) ?? link.string("urlfb", log: &log)
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log.error("native.link.url.empty", "`link.url` is required and must not be empty.", at: link.pointer.appending("url"))
        }
        return AdLink(url: url, clickTrackers: trackers, fallback: fallback)
    }

    private mutating func decodeEventTracker(_ tracker: JSONObjectReader) -> NativeEventTracker? {
        let event = tracker.int("event", log: &log)
        let method = tracker.int("method", log: &log)
        if event == nil { log.warning("native.eventtracker.event.missing", "An event tracker needs `event`; it was skipped.", at: tracker.pointer.appending("event")) }
        if method == nil { log.warning("native.eventtracker.method.missing", "An event tracker needs `method`; it was skipped.", at: tracker.pointer.appending("method")) }
        guard let url = tracker.string("url", log: &log), !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.warning("native.eventtracker.url.missing", "An image or JavaScript event tracker needs `url`; it was skipped.",
                        at: tracker.pointer.appending("url"))
            return nil
        }
        guard let event, let method else { return nil }
        return NativeEventTracker(event: event, method: method, url: url)
    }
}
