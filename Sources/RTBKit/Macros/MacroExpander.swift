import Foundation

/// OpenRTB `${…}` and VAST `[…]` macro expansion (design D4). Owner: kit-openrtb.
public enum MacroExpander {
    public static func expand(_ template: String, context: MacroContext) -> ExpandedURL {
        ExpandedURL(url: template)
    }
}
