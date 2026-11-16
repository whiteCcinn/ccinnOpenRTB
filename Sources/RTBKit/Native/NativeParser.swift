import Foundation

/// Native 1.0 / 1.1 / 1.2 response parser (design D5). Owner: kit-openrtb.
public enum NativeParser {
    public static func parse(_ json: String, hints: NativeRequestHints? = nil) -> (ad: NativeAd?, issues: [ValidationIssue]) {
        (nil, [])
    }
}
