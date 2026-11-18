import Foundation
import RTBKit

/// A text-like Native asset placed in a layout slot.
struct NativeTextItem: Equatable, Sendable {
    var assetID: Int
    var text: String
    /// The asset's own link (a tap on it reports `click(assetID:)`).
    var link: AdLink?
    /// The slot was chosen by heuristics (Native 1.0/1.1 without the request).
    var inferred: Bool
}

struct NativeImageItem: Equatable, Sendable {
    var assetID: Int
    var url: String
    var width: Int?
    var height: Int?
    var link: AdLink?
    var inferred: Bool
}

struct NativeVideoItem: Equatable, Sendable {
    var assetID: Int
    /// VAST markup (or a VAST tag URL).
    var vastTag: String
    var link: AdLink?
}

/// The Native ad's assets resolved into layout slots (pure). Typed assets win; untyped ones fill the remaining slots by
/// heuristics and are marked `inferred`.
struct NativeAdContent: Equatable, Sendable {
    var title: NativeTextItem?
    var icon: NativeImageItem?
    var mainImage: NativeImageItem?
    var logo: NativeImageItem?
    var video: NativeVideoItem?
    var data: [NativeDataType: NativeTextItem] = [:]
    /// 0…5 stars, from the rating data asset.
    var rating: Double?

    var sponsored: NativeTextItem? { data[.sponsored] }
    var body: NativeTextItem? { data[.description] ?? data[.description2] }
    var callToAction: NativeTextItem? { data[.callToAction] }
    var price: NativeTextItem? { data[.price] }
    var salePrice: NativeTextItem? { data[.salePrice] }
    var displayURL: NativeTextItem? { data[.displayURL] }
    var downloads: NativeTextItem? { data[.downloads] }
    var likes: NativeTextItem? { data[.likes] }

    /// Asset ids whose slot was inferred.
    var inferredAssetIDs: [Int] {
        let texts = [title].compactMap { $0 } + Array(data.values)
        let images = [icon, mainImage, logo].compactMap { $0 }
        return (texts.filter(\.inferred).map(\.assetID) + images.filter(\.inferred).map(\.assetID)).sorted()
    }

    init(ad: NativeAd) {
        var untypedImages: [NativeAsset] = []
        var untypedData: [NativeAsset] = []
        for asset in ad.assets {
            switch asset.content {
            case let .title(text):
                if title == nil, !text.isEmpty { title = NativeTextItem(assetID: asset.id, text: text, link: asset.link, inferred: false) }
            case let .image(url, width, height, type):
                guard !url.isEmpty else { continue }
                let item = NativeImageItem(assetID: asset.id, url: url, width: width, height: height, link: asset.link,
                                           inferred: asset.typeSource == .inferred)
                switch type {
                case .icon: if icon == nil { icon = item }
                case .main: if mainImage == nil { mainImage = item }
                case .logo: if logo == nil { logo = item }
                case nil: untypedImages.append(asset)
                }
            case let .video(vastTag):
                if video == nil, !vastTag.isEmpty { video = NativeVideoItem(assetID: asset.id, vastTag: vastTag, link: asset.link) }
            case let .data(value, _, type):
                guard !value.isEmpty else { continue }
                if let type {
                    if data[type] == nil {
                        data[type] = NativeTextItem(assetID: asset.id, text: value, link: asset.link, inferred: asset.typeSource == .inferred)
                    }
                } else {
                    untypedData.append(asset)
                }
            }
        }
        fillUntypedImages(untypedImages)
        fillUntypedData(untypedData)
        if let ratingItem = data[.rating] { rating = Self.stars(ratingItem.text) }
    }

    private mutating func fillUntypedImages(_ assets: [NativeAsset]) {
        // Sized assets first: a small square image is an icon, anything else a main image.
        let ordered = assets.sorted { lhs, rhs in Self.isSized(lhs) && !Self.isSized(rhs) }
        for asset in ordered {
            guard case let .image(url, width, height, _) = asset.content else { continue }
            let item = NativeImageItem(assetID: asset.id, url: url, width: width, height: height, link: asset.link, inferred: true)
            if Self.looksLikeIcon(width: width, height: height) {
                if icon == nil { icon = item } else if mainImage == nil { mainImage = item }
            } else if mainImage == nil {
                mainImage = item
            } else if icon == nil, width == nil {
                // A second unsized image next to a main image is most likely the icon.
                icon = item
            }
        }
    }

    private mutating func fillUntypedData(_ assets: [NativeAsset]) {
        for asset in assets {
            guard case let .data(value, label, _) = asset.content else { continue }
            var type = NativeDataClassifier.classify(value: value, label: label)
            if data[type] != nil, type == .description { type = .description2 }
            guard data[type] == nil else { continue }
            data[type] = NativeTextItem(assetID: asset.id, text: value, link: asset.link, inferred: true)
        }
    }

    private static func isSized(_ asset: NativeAsset) -> Bool {
        if case let .image(_, width, height, _) = asset.content { return width != nil && height != nil }
        return false
    }

    static func looksLikeIcon(width: Int?, height: Int?) -> Bool {
        guard let width, let height, width > 0, height > 0 else { return false }
        let ratio = Double(width) / Double(height)
        return max(width, height) <= 300 && ratio > 0.8 && ratio < 1.25
    }

    /// The leading number of a rating (`4.5`, `4.5/5`, `4,5 stars`), clamped to 0…5.
    static func stars(_ text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let range = normalized.range(of: #"\d+(\.\d+)?"#, options: .regularExpression),
              let value = Double(normalized[range]), value.isFinite else { return nil }
        return min(5, max(0, value))
    }
}

/// Heuristics for data assets without a type (Native 1.0/1.1 responses read without the bid request).
enum NativeDataClassifier {
    static func classify(value: String, label: String?) -> NativeDataType {
        if let label, let type = fromLabel(label) { return type }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if text.count <= 4, let number = Double(text.replacingOccurrences(of: ",", with: ".")), (0...5).contains(number) {
            return .rating
        }
        if lowered == "free" || matches(text, #"^[$€£¥₹]\s?\d"#) || matches(text, #"^\d+([.,]\d+)?\s?(USD|EUR|GBP|JPY|CNY|MYR|RM)$"#) {
            return .price
        }
        if text.count <= 25, matches(lowered, #"^(install|download|get|shop|buy|learn more|sign up|play|open|book|subscribe|view|watch|try|order|apply|register|see more)\b"#) {
            return .callToAction
        }
        if !text.contains(" "), matches(lowered, #"^(https?://)?(www\.)?[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/\S*)?$"#) {
            return .displayURL
        }
        if matches(lowered, #"^[\d.,]+\s?[km+]*\s?(downloads|installs)$"#) { return .downloads }
        return text.count <= 25 ? .sponsored : .description
    }

    private static func fromLabel(_ label: String) -> NativeDataType? {
        let lowered = label.lowercased()
        let table: [(String, NativeDataType)] = [
            ("sponsor", .sponsored), ("brand", .sponsored), ("advertiser", .sponsored), ("desc", .description), ("body", .description),
            ("rating", .rating), ("star", .rating), ("sale", .salePrice), ("price", .price), ("cta", .callToAction),
            ("button", .callToAction), ("action", .callToAction), ("url", .displayURL), ("domain", .displayURL),
            ("download", .downloads), ("like", .likes), ("phone", .phone), ("address", .address),
        ]
        return table.first { lowered.contains($0.0) }?.1
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// The three Native layouts (design D5).
enum NativeLayoutKind: String, Equatable, Sendable {
    /// Icon, title, sponsored, description, main image or video, CTA.
    case inFeedCard
    /// Large image first, then the text.
    case contentStream
    /// Icon, rating, price, Install CTA.
    case appInstall

    static func choose(placement: Placement, content: NativeAdContent) -> NativeLayoutKind {
        let ctaText = content.callToAction?.text.lowercased() ?? ""
        let installCTA = ["install", "download", "get", "play now", "open app"].contains { ctaText.hasPrefix($0) }
        let appSignals = content.rating != nil || content.price != nil || content.salePrice != nil || content.downloads != nil || installCTA
        if content.icon != nil, appSignals { return .appInstall }
        let hasMedia = content.mainImage != nil || content.video != nil
        if hasMedia, content.icon == nil || MRAIDEnvironment.isInterstitial(placement) { return .contentStream }
        return .inFeedCard
    }
}
