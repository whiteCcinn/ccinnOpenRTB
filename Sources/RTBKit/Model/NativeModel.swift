import Foundation

// Native 1.0 / 1.1 / 1.2 response model (design D5).

/// Native image asset type (`img.type`).
public enum NativeImageType: Int, Sendable, Hashable, Codable {
    case icon = 1
    /// Native 1.0 only ("logo"); later versions reserve it.
    case logo = 2
    case main = 3
}

/// Native data asset type (`data.type`).
public enum NativeDataType: Int, Sendable, Hashable, Codable, CaseIterable {
    case sponsored = 1, description = 2, rating = 3, likes = 4, downloads = 5, price = 6, salePrice = 7, phone = 8
    case address = 9, description2 = 10, displayURL = 11, callToAction = 12
}

/// How an asset's type was determined (1.0/1.1 responses do not always carry it).
public enum NativeTypeSource: String, Sendable, Hashable {
    case response, request, inferred, unknown
}

public struct NativeAsset: Sendable, Hashable, Identifiable {
    public enum Content: Sendable, Hashable {
        case title(text: String)
        case image(url: String, width: Int?, height: Int?, type: NativeImageType?)
        case video(vastTag: String)
        case data(value: String, label: String?, type: NativeDataType?)
    }

    /// Asset id from the response; synthesised (negative, by position) when missing.
    public var id: Int
    public var required: Bool
    public var content: Content
    /// Asset-specific link, overriding the ad link.
    public var link: AdLink?
    /// Where the image/data type came from.
    public var typeSource: NativeTypeSource

    public init(id: Int, required: Bool = false, content: Content, link: AdLink? = nil, typeSource: NativeTypeSource = .response) {
        self.id = id
        self.required = required
        self.content = content
        self.link = link
        self.typeSource = typeSource
    }
}

/// Native 1.2 `eventtrackers` entry.
public struct NativeEventTracker: Sendable, Hashable {
    /// 1 impression, 2 viewable-mrc50, 3 viewable-mrc100, 4 viewable-video50, 500+ exchange-specific.
    public var event: Int
    /// 1 image pixel, 2 JavaScript.
    public var method: Int
    public var url: String

    public init(event: Int, method: Int, url: String) {
        self.event = event
        self.method = method
        self.url = url
    }
}

public struct NativeAd: Sendable, Hashable {
    /// Declared `ver` (string or number in the response), or `nil`.
    public var version: String?
    /// The response used the `{"native": …}` wrapper (1.0/1.1 style).
    public var wrapped: Bool
    public var assets: [NativeAsset]
    public var link: AdLink
    /// `imptrackers` (impression pixels).
    public var impressionTrackers: [String]
    /// `jstracker` (HTML/JS markup, not a URL).
    public var jsTracker: String?
    public var eventTrackers: [NativeEventTracker]
    /// AdChoices / privacy URL.
    public var privacyURL: String?
    /// `assetsurl` / `dcourl`: assets delivered by a content request.
    public var assetsURL: String?
    public var dcoURL: String?

    public init(version: String? = nil, wrapped: Bool = false, assets: [NativeAsset] = [], link: AdLink = AdLink(url: ""),
                impressionTrackers: [String] = [], jsTracker: String? = nil, eventTrackers: [NativeEventTracker] = [],
                privacyURL: String? = nil, assetsURL: String? = nil, dcoURL: String? = nil) {
        self.version = version
        self.wrapped = wrapped
        self.assets = assets
        self.link = link
        self.impressionTrackers = impressionTrackers
        self.jsTracker = jsTracker
        self.eventTrackers = eventTrackers
        self.privacyURL = privacyURL
        self.assetsURL = assetsURL
        self.dcoURL = dcoURL
    }
}

/// Asset types declared by the Native request (`imp.native.request`), keyed by asset id.
public struct NativeRequestHints: Sendable, Hashable {
    public enum AssetHint: Sendable, Hashable {
        case title(maxLength: Int?)
        case image(type: NativeImageType?, width: Int?, height: Int?)
        case video
        case data(type: NativeDataType?, maxLength: Int?)
    }

    public var version: String?
    public var assets: [Int: AssetHint]
    public var required: Set<Int>

    public init(version: String? = nil, assets: [Int: AssetHint] = [:], required: Set<Int> = []) {
        self.version = version
        self.assets = assets
        self.required = required
    }
}
