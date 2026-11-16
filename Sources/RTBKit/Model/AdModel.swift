import Foundation

// Shared contracts (design D2). Parsers in OpenRTB/, Native/ and VAST/ produce these; the app renders them and the
// tracking plan reads them. Value types only.

/// The kind of ad a bid carries.
public enum AdFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case banner, native, video, audio
}

/// Ad size in CSS pixels / points.
public struct AdSize: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Where a VAST document comes from.
public enum VASTSource: Sendable, Hashable {
    /// Inline XML (`adm`).
    case xml(String)
    /// A VAST tag URL (OpenRTB 3.0 `video.curl`, or a pasted URL), fetched as a content request.
    case url(String)
}

/// OpenRTB 3.0 / AdCOM `display.banner`: an image with a link.
public struct ImageBanner: Sendable, Hashable {
    public var imageURL: String
    public var link: AdLink?

    public init(imageURL: String, link: AdLink? = nil) {
        self.imageURL = imageURL
        self.link = link
    }
}

/// A click destination with its trackers (Native `link`, AdCOM `LinkAsset`).
public struct AdLink: Sendable, Hashable {
    public var url: String
    public var clickTrackers: [String]
    public var fallback: String?

    public init(url: String, clickTrackers: [String] = [], fallback: String? = nil) {
        self.url = url
        self.clickTrackers = clickTrackers
        self.fallback = fallback
    }
}

/// The markup of a bid.
public enum AdMarkup: Sendable, Hashable {
    /// HTML / rich media (MRAID), rendered in a web view.
    case html(String)
    /// OpenRTB 3.0 image banner.
    case image(ImageBanner)
    /// Raw Native response JSON (wrapped or unwrapped), parsed by `NativeParser`.
    case native(String)
    /// VAST, inline or by URL.
    case vast(VASTSource)
    /// No markup in the bid: it is delivered by the win notice (`nurl`) or AdCOM `curl`.
    case none
}

/// OpenRTB 3.0 / AdCOM `Event` (display event trackers).
public struct AdcomEvent: Sendable, Hashable {
    /// AdCOM event type: 1 impression, 2 viewable-mrc50, 3 viewable-mrc100, 4 viewable-video50, 500+ exchange-specific.
    public var type: Int
    /// AdCOM event tracking method: 1 image pixel, 2 JavaScript.
    public var method: Int
    public var url: String?
    /// JavaScript tracker markup when `method == 2` and `url` is absent.
    public var script: String?

    public init(type: Int, method: Int, url: String? = nil, script: String? = nil) {
        self.type = type
        self.method = method
        self.url = url
        self.script = script
    }
}

/// One bid, normalised across OpenRTB 2.x and 3.0.
public struct AdCandidate: Sendable, Hashable, Identifiable {
    /// Unique within the response: `"<seatIndex>.<bidIndex>"`.
    public var id: String
    public var bidID: String
    public var impID: String?
    public var seat: String?
    public var price: Double
    public var currency: String
    public var dealID: String?
    public var adID: String?
    public var creativeID: String?
    public var campaignID: String?
    public var advertiserDomains: [String]
    public var bundle: String?
    public var size: AdSize?
    public var format: AdFormat
    public var markup: AdMarkup
    /// Win notice template (`nurl` in 2.x, `purl` in 3.0), unexpanded.
    public var winURL: String?
    /// Billing notice template (`burl`), unexpanded.
    public var billingURL: String?
    /// Loss notice template (`lurl`), unexpanded.
    public var lossURL: String?
    /// OpenRTB 3.0 `display.event`.
    public var adcomEvents: [AdcomEvent]
    /// OpenRTB 3.0 `bid.macro` (`${KEY}` → value).
    public var customMacros: [String: String]
    public var expirySeconds: Int?
    /// `mtype` (2.6) or `nil`.
    public var markupType: Int?
    public var ext: JSONValue?

    public init(id: String, bidID: String, impID: String? = nil, seat: String? = nil, price: Double, currency: String = "USD",
                dealID: String? = nil, adID: String? = nil, creativeID: String? = nil, campaignID: String? = nil,
                advertiserDomains: [String] = [], bundle: String? = nil, size: AdSize? = nil, format: AdFormat, markup: AdMarkup,
                winURL: String? = nil, billingURL: String? = nil, lossURL: String? = nil, adcomEvents: [AdcomEvent] = [],
                customMacros: [String: String] = [:], expirySeconds: Int? = nil, markupType: Int? = nil, ext: JSONValue? = nil) {
        self.id = id
        self.bidID = bidID
        self.impID = impID
        self.seat = seat
        self.price = price
        self.currency = currency
        self.dealID = dealID
        self.adID = adID
        self.creativeID = creativeID
        self.campaignID = campaignID
        self.advertiserDomains = advertiserDomains
        self.bundle = bundle
        self.size = size
        self.format = format
        self.markup = markup
        self.winURL = winURL
        self.billingURL = billingURL
        self.lossURL = lossURL
        self.adcomEvents = adcomEvents
        self.customMacros = customMacros
        self.expirySeconds = expirySeconds
        self.markupType = markupType
        self.ext = ext
    }
}

/// OpenRTB protocol version of a pasted bid response.
public enum OpenRTBVersion: Sendable, Hashable, CustomStringConvertible {
    /// 2.x; the string is `"2.6"` / `"2.5"` when fields prove it, otherwise `"2.x"` (or the declared version).
    case v2(String)
    /// 3.x with AdCOM; the string is `openrtb.ver`.
    case v3(String)

    public var description: String {
        switch self {
        case let .v2(version), let .v3(version): "OpenRTB \(version)"
        }
    }
}

/// What the pasted text is.
public enum InputKind: Sendable, Hashable {
    case bidResponse(OpenRTBVersion)
    case nativeMarkup
    case vastMarkup
    case vastURL
    case htmlMarkup
    case empty
    case invalid(String)
}

/// Result of parsing the right-hand panel.
public struct ParsedInput: Sendable, Hashable {
    public var kind: InputKind
    public var responseID: String?
    public var bidResponseID: String?
    public var currency: String?
    /// OpenRTB no-bid reason (`nbr`).
    public var noBidReason: Int?
    public var candidates: [AdCandidate]
    public var issues: [ValidationIssue]
    /// The optional bid request, when one was given and parsed.
    public var request: BidRequestSummary?

    public init(kind: InputKind, responseID: String? = nil, bidResponseID: String? = nil, currency: String? = nil, noBidReason: Int? = nil,
                candidates: [AdCandidate] = [], issues: [ValidationIssue] = [], request: BidRequestSummary? = nil) {
        self.kind = kind
        self.responseID = responseID
        self.bidResponseID = bidResponseID
        self.currency = currency
        self.noBidReason = noBidReason
        self.candidates = candidates
        self.issues = issues
        self.request = request
    }
}

/// What the optional bid request contributes (design D3).
public struct BidRequestSummary: Sendable, Hashable {
    public struct Impression: Sendable, Hashable {
        public var id: String
        /// Media types the impression offers.
        public var formats: Set<AdFormat>
        public var size: AdSize?
        /// `imp.secure == 1`: creatives and trackers must be HTTPS.
        public var secure: Bool
        public var nativeHints: NativeRequestHints?

        public init(id: String, formats: Set<AdFormat>, size: AdSize? = nil, secure: Bool = false, nativeHints: NativeRequestHints? = nil) {
            self.id = id
            self.formats = formats
            self.size = size
            self.secure = secure
            self.nativeHints = nativeHints
        }
    }

    public var id: String
    public var impressions: [Impression]
    public var currencies: [String]
    /// OpenRTB `device.devicetype`, when present.
    public var deviceType: Int?

    public init(id: String, impressions: [Impression], currencies: [String] = [], deviceType: Int? = nil) {
        self.id = id
        self.impressions = impressions
        self.currencies = currencies
        self.deviceType = deviceType
    }
}

/// A spec-validation finding.
public struct ValidationIssue: Sendable, Hashable, Identifiable {
    public enum Severity: String, Sendable, Hashable, Comparable, CaseIterable {
        case info, warning, error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            let order: [Severity] = [.info, .warning, .error]
            return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
        }
    }

    public var severity: Severity
    /// Stable identifier, e.g. `openrtb.bid.price.missing`, `vast.inline.impression.missing`.
    public var code: String
    public var message: String
    /// JSON pointer (`/seatbid/0/bid/0/adm`) or VAST element path (`VAST/Ad[1]/InLine/Impression`).
    public var path: String

    public var id: String { code + "@" + path }

    public init(_ severity: Severity, code: String, message: String, path: String) {
        self.severity = severity
        self.code = code
        self.message = message
        self.path = path
    }
}
