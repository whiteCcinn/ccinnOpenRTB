import Foundation
import RTBKit

/// What an ad unit asks for.
enum PrebidMediaType: String, Codable, CaseIterable, Identifiable, Sendable {
    case banner, video, native
    var id: String { rawValue }
}

/// One bidder of an ad unit and its params, as typed (a JSON object).
struct PrebidBidderParams: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var bidder: String
    var params: String

    init(bidder: String, params: String = "{}") {
        self.bidder = bidder
        self.params = params
    }
}

struct PrebidAdUnit: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var code: String
    var mediaType: PrebidMediaType
    /// Banner sizes, or the video player size (the first).
    var sizes: [AdSize]
    var bids: [PrebidBidderParams]

    init(code: String, mediaType: PrebidMediaType, sizes: [AdSize], bids: [PrebidBidderParams]) {
        self.code = code
        self.mediaType = mediaType
        self.sizes = sizes
        self.bids = bids
    }
}

/// Static consent for the page (`consentManagement` with `cmpApi: 'static'`): never a CMP lookup, which cancels the
/// auction when no CMP is on the page.
struct PrebidConsent: Codable, Hashable, Sendable {
    /// `nil`: no TCF module at all.
    var gdprApplies: Bool?
    var tcString = ""
    var usPrivacy = ""
    var gppString = ""
    var gppSectionIDs: [Int] = []

    var configuresTCF: Bool { gdprApplies != nil }
    var configuresUSP: Bool { !usPrivacy.isEmpty }
    var configuresGPP: Bool { !gppString.isEmpty }
}

/// A Prebid page: the Prebid.js version, the publisher page it pretends to be, ad units with their bidders, timeout and
/// consent. Pure; `PrebidPage` turns it into HTML.
struct PrebidSetup: Codable, Hashable, Sendable {
    var version: String
    var pageURL = "https://news.example/article"
    var adUnits: [PrebidAdUnit] = []
    var timeoutMilliseconds = 1_500
    var consent = PrebidConsent()

    init(version: String) {
        self.version = version
    }

    enum Problem: Hashable, Sendable {
        case noAdUnits
        case missingCode(index: Int)
        case noBidders(adUnit: String)
        case noSizes(adUnit: String)
        case unknownBidder(String)
        case paramsNotAnObject(adUnit: String, bidder: String)
        case invalidPageURL

        var message: String {
            switch self {
            case .noAdUnits: "Add an ad unit."
            case let .missingCode(index): "Ad unit \(index + 1) has no code (the div id Prebid reports bids for)."
            case let .noBidders(adUnit): "“\(adUnit)” has no bidder."
            case let .noSizes(adUnit): "“\(adUnit)” has no size."
            case let .unknownBidder(code): "“\(code)” is not a bidder of this Prebid.js version."
            case let .paramsNotAnObject(adUnit, bidder): "The params of \(bidder) in “\(adUnit)” are not a JSON object."
            case .invalidPageURL: "The page URL must be an https URL: it is what the bidders see as the page."
            }
        }
    }

    struct Invalid: Error, Hashable, Sendable {
        var problems: [Problem]
    }

    func problems(catalog: [String: PrebidBidder]) -> [Problem] {
        var problems: [Problem] = []
        if URL(string: pageURL)?.scheme != "https" || URL(string: pageURL)?.host?.isEmpty != false { problems.append(.invalidPageURL) }
        if adUnits.isEmpty { problems.append(.noAdUnits) }
        for (index, unit) in adUnits.enumerated() {
            let code = unit.code.trimmingCharacters(in: .whitespaces)
            if code.isEmpty { problems.append(.missingCode(index: index)) }
            if unit.bids.isEmpty { problems.append(.noBidders(adUnit: unit.code)) }
            if unit.sizes.isEmpty, unit.mediaType != .native { problems.append(.noSizes(adUnit: unit.code)) }
            for bid in unit.bids {
                if catalog[bid.bidder] == nil, !problems.contains(.unknownBidder(bid.bidder)) { problems.append(.unknownBidder(bid.bidder)) }
                guard case .object? = try? JSONValue.parse(bid.params) else {
                    problems.append(.paramsNotAnObject(adUnit: unit.code, bidder: bid.bidder))
                    continue
                }
            }
        }
        return problems
    }

    /// The modules the loader loads: the bidders' adapters (an alias loads its parent's module) and the consent modules
    /// in use, sorted, once each.
    func modules(catalog: [String: PrebidBidder]) throws(Invalid) -> [String] {
        let problems = problems(catalog: catalog)
        guard problems.isEmpty else { throw Invalid(problems: problems) }
        var modules = Set(adUnits.flatMap(\.bids).compactMap { catalog[$0.bidder]?.module })
        if consent.configuresTCF { modules.insert("consentManagementTcf") }
        if consent.configuresUSP { modules.insert("consentManagementUsp") }
        if consent.configuresGPP { modules.insert("consentManagementGpp") }
        return modules.sorted()
    }

    /// The GVL ids of the bidders in use (consented under static TCF consent).
    func vendorIDs(catalog: [String: PrebidBidder]) -> [Int] {
        Array(Set(adUnits.flatMap(\.bids).compactMap { catalog[$0.bidder]?.gvlid })).sorted()
    }
}
