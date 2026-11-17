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
        let deviceType = device?.int("devicetype", log: &log)
        var context = RequestContextReader(log: log)
        context.readPublisher(site: request.object("site", log: &context.log), app: request.object("app", log: &context.log))
        context.readDevice(device)
        let user = request.object("user", log: &context.log)
        context.set("[GDPRCONSENT]", user?.string("consent", log: &context.log) ?? user?.object("ext", log: &context.log)?.string("consent", log: &context.log))
        // 2.6 `source.tid`; 2.5 exchanges often sent it in `source.ext.tid`.
        let source = request.object("source", log: &context.log)
        context.transactionID = source?.string("tid", log: &context.log) ?? source?.object("ext", log: &context.log)?.string("tid", log: &context.log)
        context.set("[BLOCKEDADCATEGORIES]", joined(request.strings("bcat", log: &context.log)))
        log = context.log
        let summary = context.summary(id: id, impressions: impressions, currencies: request.strings("cur", log: &log) ?? [], deviceType: deviceType)
        return BidRequestInfo(summary: summary, vastMacros: context.macroValues, impressionMacros: impressionMacros)
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
        let contextObject = request.object("context", log: &log)
        let device = contextObject?.object("device", log: &log)
        let deviceType = device?.int("type", log: &log)
        var context = RequestContextReader(log: log)
        context.readPublisher(site: contextObject?.object("site", log: &context.log), app: contextObject?.object("app", log: &context.log))
        context.readDevice(device)
        context.set("[GDPRCONSENT]", contextObject?.object("user", log: &context.log)?.string("consent", log: &context.log))
        context.transactionID = request.object("source", log: &context.log)?.string("tid", log: &context.log)
        context.set("[BLOCKEDADCATEGORIES]", joined(contextObject?.object("restrictions", log: &context.log)?.strings("bcat", log: &context.log)))
        log = context.log
        let summary = context.summary(id: id, impressions: impressions, currencies: request.strings("cur", log: &log) ?? [], deviceType: deviceType)
        return BidRequestInfo(summary: summary, vastMacros: context.macroValues, impressionMacros: impressionMacros)
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

/// Reads the publisher, device and source context shared by OpenRTB 2.x and AdCOM (same field names): the
/// `BidRequestSummary` fields VAST macros need, plus the other request-derived VAST 4.x macro values (VAST 4.1 §6.2 names).
private struct RequestContextReader {
    var log: IssueLog
    var domain: String?
    var pageURL: String?
    var appBundle: String?
    var ifa: String?
    var limitAdTracking: Bool?
    var transactionID: String?
    /// Other request-derived values under bracketed VAST macro names (`[DEVICEIP]`, `[LATLONG]`, …).
    private(set) var extraMacros: [String: String] = [:]

    init(log: IssueLog) {
        self.log = log
    }

    mutating func set(_ key: String, _ value: String?) {
        guard let value = nonEmpty(value) else { return }
        extraMacros[key] = value
    }

    /// `site.domain`, else the host of `site.page` (the top-level page), else `app.domain`.
    mutating func readPublisher(site: JSONObjectReader?, app: JSONObjectReader?) {
        if let site {
            pageURL = nonEmpty(site.string("page", log: &log))
            domain = nonEmpty(site.string("domain", log: &log)) ?? pageURL.flatMap { nonEmpty(URLComponents(string: $0)?.host) }
            readContent(site.object("content", log: &log))
        }
        if let app {
            appBundle = nonEmpty(app.string("bundle", log: &log))
            let appDomain = nonEmpty(app.string("domain", log: &log))
            if domain == nil { domain = appDomain }
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
        ifa = nonEmpty(device.string("ifa", log: &log))
        limitAdTracking = device.flag("lmt", log: &log)
        set("[DEVICEUA]", device.string("ua", log: &log))
        set("[DEVICEIP]", device.string("ip", log: &log) ?? device.string("ipv6", log: &log))
        set("[IFATYPE]", device.object("ext", log: &log)?.string("ifa_type", log: &log))
        if let geo = device.object("geo", log: &log), let latitude = geo.double("lat", log: &log), let longitude = geo.double("lon", log: &log),
           let lat = MacroEncoding.decimal(latitude), let lon = MacroEncoding.decimal(longitude) {
            set("[LATLONG]", lat + "," + lon)
        }
    }

    func summary(id: String, impressions: [BidRequestSummary.Impression], currencies: [String], deviceType: Int?) -> BidRequestSummary {
        BidRequestSummary(id: id, impressions: impressions, currencies: currencies, deviceType: deviceType, domain: domain, pageURL: pageURL,
                          appBundle: appBundle, ifa: ifa, limitAdTracking: limitAdTracking, transactionID: nonEmpty(transactionID))
    }

    /// Every request-derived VAST macro value under its bracketed name.
    var macroValues: [String: String] {
        var values = extraMacros
        let typed: [(String, String?)] = [("[DOMAIN]", domain), ("[PAGEURL]", pageURL), ("[APPBUNDLE]", appBundle), ("[IFA]", ifa),
                                          ("[LIMITADTRACKING]", limitAdTracking.map { $0 ? "1" : "0" }), ("[TRANSACTIONID]", nonEmpty(transactionID))]
        for (key, value) in typed { if let value { values[key] = value } }
        return values
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
