import Foundation

/// Heuristics for Native 1.0/1.1 asset types that neither the response nor the request declares. Results are always
/// labelled `.inferred` (design D5, "Native 1.0/1.1 data types without the request are heuristics").
enum NativeTypeInference {
    /// Square and small → icon; otherwise main. A URL naming "icon" or "logo" wins.
    static func imageType(url: String, width: Int?, height: Int?) -> NativeImageType {
        let lowered = url.lowercased()
        if lowered.contains("icon") { return .icon }
        if lowered.contains("logo") { return .logo }
        if let width, let height, width > 0, height > 0 {
            let ratio = Double(width) / Double(height)
            if (0.8...1.25).contains(ratio), max(width, height) <= 300 { return .icon }
        }
        return .main
    }

    /// From the 1.0/1.1 `label`, then from the shape of the value; `nil` when nothing is convincing.
    static func dataType(label: String?, value: String) -> NativeDataType? {
        if let label, let type = dataType(forLabel: label) { return type }
        return dataType(forValue: value)
    }

    private static let labelKeywords: [(keywords: [String], type: NativeDataType)] = [
        (["sponsor", "advertiser", "brand"], .sponsored),
        (["sale"], .salePrice),
        (["price", "cost"], .price),
        (["rating", "stars", "score"], .rating),
        (["like"], .likes),
        (["download", "install"], .downloads),
        (["phone", "tel"], .phone),
        (["address", "location"], .address),
        (["url", "website", "domain"], .displayURL),
        (["cta", "call to action", "call-to-action", "button"], .callToAction),
        (["desc", "body", "text"], .description),
    ]

    private static func dataType(forLabel label: String) -> NativeDataType? {
        let lowered = label.lowercased()
        return labelKeywords.first { entry in entry.keywords.contains { lowered.contains($0) } }?.type
    }

    private static let callToActionWords: Set<String> = [
        "install", "download", "learn", "shop", "buy", "get", "play", "book", "order", "subscribe", "watch", "visit", "apply", "try",
        "open", "sign", "register", "donate", "contact", "call", "more", "now", "start", "join", "listen", "read", "view", "see",
    ]

    private static func dataType(forValue value: String) -> NativeDataType? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("sponsored") || lowered.hasPrefix("ad by") || lowered.hasPrefix("promoted") { return .sponsored }
        if let number = Double(trimmed), number.isFinite, (0...5).contains(number), trimmed.count <= 4 { return .rating }
        if lowered == "free" || trimmed.first.map({ "$€£¥₹₩".contains($0) }) == true { return .price }
        let digits = trimmed.filter(\.isNumber).count
        if digits >= 7, trimmed.allSatisfy({ $0.isNumber || "+-() .".contains($0) }) { return .phone }
        if !trimmed.contains(" "), trimmed.contains("."), !trimmed.contains("@"), trimmed.count <= 64,
           trimmed.last?.isLetter == true { return .displayURL }
        let words = lowered.split(whereSeparator: { $0 == " " || $0 == "!" })
        if (1...3).contains(words.count), trimmed.count <= 25, words.contains(where: { callToActionWords.contains(String($0)) }) {
            return .callToAction
        }
        if trimmed.count > 25 { return .description }
        return nil
    }
}
