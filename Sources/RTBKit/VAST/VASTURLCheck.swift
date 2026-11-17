import Foundation

/// URL checks for VAST elements. Macros (`[ERRORCODE]`, `${AUCTION_PRICE}`) are allowed anywhere, because the URLs
/// are templates.
enum VASTURLCheck {
    /// What a URL is used for decides which schemes are acceptable.
    enum Role {
        /// Impression, Error, Tracking, ClickTracking, Viewable…: fired as HTTP requests.
        case tracker
        /// ClickThrough / CompanionClickThrough: opened in a browser.
        case clickThrough
        /// MediaFile, StaticResource, IFrameResource, JavaScriptResource: loaded as content.
        case resource
        /// VASTAdTagURI: fetched as a VAST document (`data:` allowed for offline chains).
        case adTag
    }

    enum Finding: Equatable {
        case ok
        /// `http://`: acceptable, but not secure.
        case insecure
        /// Not an absolute URL with a usable scheme.
        case invalid(String)
    }

    /// `ccinn-sample://` URLs are the simulator's own offline media and images.
    static let sampleScheme = "ccinn-sample"

    static func check(_ url: String, role: Role) -> Finding {
        guard !url.contains(where: \.isWhitespace) else { return .invalid("contains whitespace") }
        guard let scheme = scheme(of: url) else { return .invalid("not an absolute URL (no scheme)") }
        switch scheme {
        case "https":
            return host(of: url) != nil ? .ok : .invalid("missing host")
        case "http":
            return host(of: url) != nil ? .insecure : .invalid("missing host")
        case "data":
            return role == .resource || role == .adTag ? .ok : .invalid("a data: URL cannot be requested as a tracker or opened as a click-through")
        case sampleScheme:
            return role == .resource ? .ok : .invalid("ccinn-sample: URLs are only for media and images")
        default:
            return .invalid("unsupported scheme \(scheme):")
        }
    }

    /// The lower-cased scheme (`[A-Za-z][A-Za-z0-9+.-]*:`), or `nil`.
    static func scheme(of url: String) -> String? {
        guard let colon = url.firstIndex(of: ":"), colon != url.startIndex else { return nil }
        let candidate = url[..<colon]
        guard let first = candidate.first, first.isASCII, first.isLetter,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") })
        else { return nil }
        return candidate.lowercased()
    }

    /// The host of an `http(s)` URL, without the port or user info (`nil` when absent).
    static func host(of url: String) -> String? {
        guard let scheme = scheme(of: url), scheme == "http" || scheme == "https" else { return nil }
        let afterScheme = url.dropFirst(scheme.count + 1)
        guard afterScheme.hasPrefix("//") else { return nil }
        let authority = afterScheme.dropFirst(2).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? authority
        let host: Substring
        if hostAndPort.hasPrefix("["), let close = hostAndPort.firstIndex(of: "]") {
            host = hostAndPort[...close]
        } else {
            host = hostAndPort.prefix { $0 != ":" }
        }
        return host.isEmpty ? nil : String(host).lowercased()
    }
}
