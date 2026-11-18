import Foundation

/// Reads an OpenRTB 2.x `BidRequest` or an OpenRTB 3.0 `{"openrtb": {"request": …}}` into the facts the simulator uses
/// (design D3): impressions (formats, size, secure, Native hints, quantity) and the context VAST macros describe. Facts
/// stay typed here; `MacroContext.simulatorDefaults` maps them to macros. Issue paths start with `request:`.
enum BidRequestReader {
    static let rootPointer = JSONPointer(prefix: "request:")

    static func read(_ json: String) -> (summary: BidRequestSummary?, issues: [ValidationIssue]) {
        var log = IssueLog()
        guard let value = try? JSONValue.parse(json), case let .object(members) = value else {
            log.warning("request.json.invalid", "The bid request is not a JSON object; it was ignored.", at: rootPointer)
            return (nil, log.issues)
        }
        let root = JSONObjectReader(members, at: rootPointer, domain: "request")
        let summary: BidRequestSummary
        if let envelope = root.object("openrtb", log: &log) {
            guard let request = envelope.object("request", log: &log) else {
                log.warning("request.openrtb3.request.missing", "An OpenRTB 3.0 envelope without `request`; it was ignored.", at: envelope.pointer)
                return (nil, log.issues)
            }
            summary = readVersion3(request, log: &log)
        } else {
            summary = readVersion2(root, log: &log)
        }
        return (summary, log.issues)
    }

    // MARK: OpenRTB 2.x

    private static func readVersion2(_ request: JSONObjectReader, log: inout IssueLog) -> BidRequestSummary {
        let id = requiredID(request, log: &log)
        var impressions: [BidRequestSummary.Impression] = []
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
            impressions.append(BidRequestSummary.Impression(id: impID, formats: formats, size: size, secure: imp.flag("secure", log: &log) ?? false,
                                                            nativeHints: nativeHints,
                                                            quantityMultiplier: imp.object("qty", log: &log)?.double("multiplier", log: &log)))
        }
        let device = request.object("device", log: &log)
        var facts = RequestFacts(id: id, impressions: impressions, log: log)
        facts.currencies = request.strings("cur", log: &facts.log) ?? []
        facts.deviceType = device?.int("devicetype", log: &facts.log)
        facts.readPublisher(site: request.object("site", log: &facts.log), app: request.object("app", log: &facts.log))
        facts.readDevice(device)
        // 2.6 `user.consent`; 2.5-era requests carried it in `user.ext.consent`.
        let user = request.object("user", log: &facts.log)
        facts.gdprConsent = nonEmpty(user?.string("consent", log: &facts.log)) ?? nonEmpty(user?.object("ext", log: &facts.log)?.string("consent", log: &facts.log))
        // 2.6 `source.tid`; 2.5-era requests often carried it in `source.ext.tid`.
        let source = request.object("source", log: &facts.log)
        facts.transactionID = nonEmpty(source?.string("tid", log: &facts.log)) ?? nonEmpty(source?.object("ext", log: &facts.log)?.string("tid", log: &facts.log))
        facts.blockedCategories = request.strings("bcat", log: &facts.log) ?? []
        log = facts.log
        return facts.summary
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

    private static func readVersion3(_ request: JSONObjectReader, log: inout IssueLog) -> BidRequestSummary {
        let id = requiredID(request, log: &log)
        var impressions: [BidRequestSummary.Impression] = []
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
            impressions.append(BidRequestSummary.Impression(id: itemID, formats: formats, size: size,
                                                            secure: placement?.flag("secure", log: &log) ?? false, nativeHints: nativeHints,
                                                            itemQuantity: itemQuantity(item, log: &log)))
        }
        let context = request.object("context", log: &log)
        let device = context?.object("device", log: &log)
        var facts = RequestFacts(id: id, impressions: impressions, log: log)
        facts.currencies = request.strings("cur", log: &facts.log) ?? []
        facts.deviceType = device?.int("type", log: &facts.log)
        facts.readPublisher(site: context?.object("site", log: &facts.log), app: context?.object("app", log: &facts.log))
        facts.readDevice(device)
        facts.gdprConsent = nonEmpty(context?.object("user", log: &facts.log)?.string("consent", log: &facts.log))
        facts.transactionID = nonEmpty(request.object("source", log: &facts.log)?.string("tid", log: &facts.log))
        facts.blockedCategories = context?.object("restrictions", log: &facts.log)?.strings("bcat", log: &facts.log) ?? []
        log = facts.log
        return facts.summary
    }

    /// OpenRTB 3.0 §4.2.3 "Object: Item": `qty` (integer, default 1) or `qtyflt` (float, "for cases where the quantity is not
    /// expressed as a whole number"); "Only one of 'qty' or 'qtyflt' may be present." When both are, the request is
    /// flagged and `qtyflt`, the only one able to hold the exact quantity, is used. A fractional `qty` is kept, flagged.
    private static func itemQuantity(_ item: JSONObjectReader, log: inout IssueLog) -> Double {
        if item.has("qty"), item.has("qtyflt") {
            log.warning("request.item.qty.conflict", "Only one of `qty` or `qtyflt` may be present (OpenRTB 3.0 §4.2.3 Item); `qtyflt` is used.",
                        at: item.pointer)
        }
        let fractional = item.double("qtyflt", log: &log)
        let whole: Double?
        if case let .double(number)? = item.raw("qty"), number.isFinite, number != number.rounded() {
            log.warning("request.item.qty.fractional", "`qty` is an integer; a quantity that is not a whole number belongs in `qtyflt`.",
                        at: item.pointer.appending("qty"))
            whole = number
        } else {
            whole = item.int("qty", log: &log).map(Double.init)
        }
        return fractional ?? whole ?? 1
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

    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// The publisher, device and source context shared by OpenRTB 2.x and AdCOM (same field names), collected into a
/// `BidRequestSummary`.
private struct RequestFacts {
    var log: IssueLog
    private var draft: BidRequestSummary

    init(id: String, impressions: [BidRequestSummary.Impression], log: IssueLog) {
        self.log = log
        draft = BidRequestSummary(id: id, impressions: impressions)
    }

    var summary: BidRequestSummary { draft }

    var currencies: [String] {
        get { draft.currencies }
        set { draft.currencies = newValue }
    }

    var deviceType: Int? {
        get { draft.deviceType }
        set { draft.deviceType = newValue }
    }

    var gdprConsent: String? {
        get { draft.gdprConsent }
        set { draft.gdprConsent = newValue }
    }

    var transactionID: String? {
        get { draft.transactionID }
        set { draft.transactionID = newValue }
    }

    var blockedCategories: [String] {
        get { draft.blockedCategories }
        set { draft.blockedCategories = newValue.filter { !$0.isEmpty } }
    }

    /// `site.domain`, else the host of `site.page` (the top-level page), else `app.domain`; content from the site, else
    /// the app.
    mutating func readPublisher(site: JSONObjectReader?, app: JSONObjectReader?) {
        if let site {
            draft.pageURL = BidRequestReader.nonEmpty(site.string("page", log: &log))
            draft.domain = BidRequestReader.nonEmpty(site.string("domain", log: &log))
                ?? draft.pageURL.flatMap { BidRequestReader.nonEmpty(URLComponents(string: $0)?.host) }
            readContent(site.object("content", log: &log))
        }
        if let app {
            draft.appBundle = BidRequestReader.nonEmpty(app.string("bundle", log: &log))
            draft.storeURL = BidRequestReader.nonEmpty(app.string("storeurl", log: &log))
            let appDomain = BidRequestReader.nonEmpty(app.string("domain", log: &log))
            if draft.domain == nil { draft.domain = appDomain }
            readContent(app.object("content", log: &log))
        }
    }

    private mutating func readContent(_ content: JSONObjectReader?) {
        guard let content else { return }
        if draft.contentID == nil { draft.contentID = BidRequestReader.nonEmpty(content.string("id", log: &log)) }
        if draft.contentURL == nil { draft.contentURL = BidRequestReader.nonEmpty(content.string("url", log: &log)) }
    }

    /// `ip` wins over `ipv6`; `ifa_type` is the IAB guidelines' `device.ext.ifa_type`.
    mutating func readDevice(_ device: JSONObjectReader?) {
        guard let device else { return }
        draft.ifa = BidRequestReader.nonEmpty(device.string("ifa", log: &log))
        draft.limitAdTracking = device.flag("lmt", log: &log)
        draft.deviceUserAgent = BidRequestReader.nonEmpty(device.string("ua", log: &log))
        draft.deviceIP = BidRequestReader.nonEmpty(device.string("ip", log: &log)) ?? BidRequestReader.nonEmpty(device.string("ipv6", log: &log))
        draft.ifaType = BidRequestReader.nonEmpty(device.object("ext", log: &log)?.string("ifa_type", log: &log))
        if let geo = device.object("geo", log: &log) {
            let latitude = geo.double("lat", log: &log)
            let longitude = geo.double("lon", log: &log)
            if let latitude, let longitude, (-90...90).contains(latitude), (-180...180).contains(longitude) {
                draft.latitude = latitude
                draft.longitude = longitude
            } else if latitude != nil || longitude != nil {
                log.warning("request.geo.invalid", "`geo.lat` / `geo.lon` must both be present, within ±90 / ±180.", at: geo.pointer)
            }
        }
    }
}
