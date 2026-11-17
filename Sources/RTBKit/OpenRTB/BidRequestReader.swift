import Foundation

/// What the simulator takes from the optional bid request: the public summary plus the values request-derived macros need.
struct BidRequestInfo {
    var summary: BidRequestSummary
    /// VAST macro values under bracketed keys (`[DOMAIN]`, `[IFA]`, …).
    var vastMacros: [String: String]
    /// Per impression / item id: OpenRTB macro values that come from the impression (`AUCTION_MULTIPLIER`, `OPENRTB_ITEM_QTY`).
    var impressionMacros: [String: [String: String]]
}

/// Reads an OpenRTB 2.x `BidRequest` or an OpenRTB 3.0 `{"openrtb": {"request": …}}`. Issue paths start with `request:`.
enum BidRequestReader {
    static let rootPointer = JSONPointer(prefix: "request:")

    static func read(_ json: String) -> (info: BidRequestInfo?, issues: [ValidationIssue]) {
        var log = IssueLog()
        guard let value = try? JSONValue.parse(json), case let .object(members) = value else {
            log.warning("request.json.invalid", "The bid request is not a JSON object; it was ignored.", at: rootPointer)
            return (nil, log.issues)
        }
        let root = JSONObjectReader(members, at: rootPointer, domain: "request")
        let info: BidRequestInfo
        if let envelope = root.object("openrtb", log: &log) {
            guard let request = envelope.object("request", log: &log) else {
                log.warning("request.openrtb3.request.missing", "An OpenRTB 3.0 envelope without `request`; it was ignored.", at: envelope.pointer)
                return (nil, log.issues)
            }
            info = readVersion3(request, log: &log)
        } else {
            info = readVersion2(root, log: &log)
        }
        return (info, log.issues)
    }

    // MARK: OpenRTB 2.x

    private static func readVersion2(_ request: JSONObjectReader, log: inout IssueLog) -> BidRequestInfo {
        let id = requiredID(request, log: &log)
        var impressions: [BidRequestSummary.Impression] = []
        var impressionMacros: [String: [String: String]] = [:]
        let imps = request.objects("imp", log: &log) ?? []
        if imps.isEmpty { log.warning("request.imp.missing", "The bid request has no `imp`.", at: request.pointer.appending("imp")) }
        for (index, imp) in imps {
            let impID = imp.string("id", log: &log) ?? String(index + 1)
            var formats: Set<AdFormat> = []
            var size: AdSize?
            if let banner = imp.object("banner", log: &log) {
                formats.insert(.banner)
                size = adSize(banner, log: &log) ?? firstSize(banner, arrayKey: "format", log: &log)
            }
            if let video = imp.object("video", log: &log) {
                formats.insert(.video)
                size = size ?? adSize(video, log: &log)
            }
            if imp.has("audio") { formats.insert(.audio) }
            var nativeHints: NativeRequestHints?
            if let native = imp.object("native", log: &log) {
                formats.insert(.native)
                nativeHints = nativeRequestHints(native, log: &log)
            }
            let secure = imp.flag("secure", log: &log) ?? false
            impressions.append(BidRequestSummary.Impression(id: impID, formats: formats, size: size, secure: secure, nativeHints: nativeHints))
            if let multiplier = imp.object("qty", log: &log)?.double("multiplier", log: &log).flatMap(MacroEncoding.decimal) {
                impressionMacros[impID, default: [:]]["AUCTION_MULTIPLIER"] = multiplier
            }
        }
        let device = request.object("device", log: &log)
        let summary = BidRequestSummary(id: id, impressions: impressions, currencies: request.strings("cur", log: &log) ?? [],
                                        deviceType: device?.int("devicetype", log: &log))
        var macros = MacroSources(log: log)
        macros.readPublisher(site: request.object("site", log: &macros.log), app: request.object("app", log: &macros.log))
        macros.readDevice(device)
        let user = request.object("user", log: &macros.log)
        macros.set("[GDPRCONSENT]", user?.string("consent", log: &macros.log) ?? user?.object("ext", log: &macros.log)?.string("consent", log: &macros.log))
        let source = request.object("source", log: &macros.log)
        macros.set("[TRANSACTIONID]", source?.string("tid", log: &macros.log) ?? source?.object("ext", log: &macros.log)?.string("tid", log: &macros.log))
        macros.set("[BLOCKEDADCATEGORIES]", joined(request.strings("bcat", log: &macros.log)))
        log = macros.log
        return BidRequestInfo(summary: summary, vastMacros: macros.values, impressionMacros: impressionMacros)
    }

    /// `imp.native.request` is a JSON string; an object is accepted with a warning.
    private static func nativeRequestHints(_ native: JSONObjectReader, log: inout IssueLog) -> NativeRequestHints? {
        let pointer = native.pointer.appending("request")
        switch native.raw("request") {
        case let .string(text):
            return NativeRequestReader.hints(fromRequestString: text, at: pointer, log: &log)
        case let .object(members):
            log.warning("request.type.mismatch", "`request` should be a JSON string holding the Native request, found an object.", at: pointer)
            return NativeRequestReader.hints(from: JSONObjectReader(members, at: pointer, domain: "request"), log: &log)
        case .some:
            log.warning("request.type.mismatch", "`request` should be a JSON string holding the Native request.", at: pointer)
            return nil
        case nil:
            log.warning("request.native.missing", "`imp.native.request` is missing.", at: pointer)
            return nil
        }
    }

    // MARK: OpenRTB 3.0

    private static func readVersion3(_ request: JSONObjectReader, log: inout IssueLog) -> BidRequestInfo {
        let id = requiredID(request, log: &log)
        var impressions: [BidRequestSummary.Impression] = []
        var impressionMacros: [String: [String: String]] = [:]
        let items = request.objects("item", log: &log) ?? []
        if items.isEmpty { log.warning("request.item.missing", "The bid request has no `item`.", at: request.pointer.appending("item")) }
        for (index, item) in items {
            let itemID = item.string("id", log: &log) ?? String(index + 1)
            var formats: Set<AdFormat> = []
            var size: AdSize?
            var nativeHints: NativeRequestHints?
            let placement = item.object("spec", log: &log)?.object("placement", log: &log)
            if let display = placement?.object("display", log: &log) {
                size = adSize(display, log: &log) ?? firstSize(display, arrayKey: "displayfmt", log: &log)
                if let nativeFormat = display.object("nativefmt", log: &log) {
                    formats.insert(.native)
                    nativeHints = NativeRequestReader.hints(from: nativeFormat, log: &log)
                } else {
                    formats.insert(.banner)
                }
            }
            if let video = placement?.object("video", log: &log) {
                formats.insert(.video)
                size = size ?? adSize(video, log: &log)
            }
            if placement?.has("audio") == true { formats.insert(.audio) }
            let secure = placement?.flag("secure", log: &log) ?? false
            impressions.append(BidRequestSummary.Impression(id: itemID, formats: formats, size: size, secure: secure, nativeHints: nativeHints))
            if let quantity = item.double("qty", log: &log).flatMap(MacroEncoding.decimal) {
                impressionMacros[itemID, default: [:]]["OPENRTB_ITEM_QTY"] = quantity
            }
        }
        let context = request.object("context", log: &log)
        let device = context?.object("device", log: &log)
        let summary = BidRequestSummary(id: id, impressions: impressions, currencies: request.strings("cur", log: &log) ?? [],
                                        deviceType: device?.int("type", log: &log))
        var macros = MacroSources(log: log)
        macros.readPublisher(site: context?.object("site", log: &macros.log), app: context?.object("app", log: &macros.log))
        macros.readDevice(device)
        macros.set("[GDPRCONSENT]", context?.object("user", log: &macros.log)?.string("consent", log: &macros.log))
        macros.set("[TRANSACTIONID]", request.object("source", log: &macros.log)?.string("tid", log: &macros.log))
        macros.set("[BLOCKEDADCATEGORIES]", joined(context?.object("restrictions", log: &macros.log)?.strings("bcat", log: &macros.log)))
        log = macros.log
        return BidRequestInfo(summary: summary, vastMacros: macros.values, impressionMacros: impressionMacros)
    }

    // MARK: Helpers

    private static func requiredID(_ request: JSONObjectReader, log: inout IssueLog) -> String {
        if let id = request.nonBlankString("id", log: &log) { return id }
        log.warning("request.id.missing", "The bid request has no `id`.", at: request.pointer.appending("id"))
        return ""
    }

    private static func adSize(_ reader: JSONObjectReader, log: inout IssueLog) -> AdSize? {
        guard let width = reader.int("w", log: &log), let height = reader.int("h", log: &log), width > 0, height > 0 else { return nil }
        return AdSize(width: width, height: height)
    }

    /// The first sized entry of `banner.format[]` / `display.displayfmt[]`.
    private static func firstSize(_ reader: JSONObjectReader, arrayKey: String, log: inout IssueLog) -> AdSize? {
        for (_, format) in reader.objects(arrayKey, log: &log) ?? [] {
            if let size = adSize(format, log: &log) { return size }
        }
        return nil
    }

    private static func joined(_ values: [String]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return values.joined(separator: ",")
    }
}

/// Collects request-derived VAST macro values (VAST 4.1 §6.2 names) from the OpenRTB / AdCOM context objects, which share
/// field names across 2.x and AdCOM.
private struct MacroSources {
    var log: IssueLog
    private(set) var values: [String: String] = [:]

    init(log: IssueLog) {
        self.log = log
    }

    mutating func set(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        values[key] = value
    }

    mutating func readPublisher(site: JSONObjectReader?, app: JSONObjectReader?) {
        if let site {
            let page = site.string("page", log: &log)
            set("[PAGEURL]", page)
            set("[DOMAIN]", site.string("domain", log: &log) ?? page.flatMap { URLComponents(string: $0)?.host })
            readContent(site.object("content", log: &log))
        }
        if let app {
            set("[APPBUNDLE]", app.string("bundle", log: &log))
            set("[STOREURL]", app.string("storeurl", log: &log))
            readContent(app.object("content", log: &log))
        }
    }

    private mutating func readContent(_ content: JSONObjectReader?) {
        guard let content else { return }
        set("[CONTENTID]", content.string("id", log: &log))
        set("[CONTENTURI]", content.string("url", log: &log))
    }

    mutating func readDevice(_ device: JSONObjectReader?) {
        guard let device else { return }
        set("[DEVICEUA]", device.string("ua", log: &log))
        set("[IFA]", device.string("ifa", log: &log))
        set("[LIMITADTRACKING]", device.flag("lmt", log: &log).map { $0 ? "1" : "0" })
        set("[DEVICEIP]", device.string("ip", log: &log) ?? device.string("ipv6", log: &log))
        set("[IFATYPE]", device.object("ext", log: &log)?.string("ifa_type", log: &log))
        if let geo = device.object("geo", log: &log), let latitude = geo.double("lat", log: &log), let longitude = geo.double("lon", log: &log),
           let lat = MacroEncoding.decimal(latitude), let lon = MacroEncoding.decimal(longitude) {
            set("[LATLONG]", lat + "," + lon)
        }
    }
}
