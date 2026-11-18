import Foundation

/// HLS playlists (RFC 8216 and its second edition): detection, and rewriting every URI they reference, so the player
/// asks the monitor for each one instead of the origin.
enum HLSPlaylist {
    /// What a playlist URI points to (the Network window labels the request with it).
    enum Kind: String, Sendable, Hashable {
        /// A variant or rendition playlist (`EXT-X-STREAM-INF`, `EXT-X-MEDIA`, `EXT-X-I-FRAME-STREAM-INF`,
        /// `EXT-X-RENDITION-REPORT`).
        case playlist
        /// A media segment or part (`EXTINF`, `EXT-X-PART`, `EXT-X-PRELOAD-HINT`).
        case segment
        /// `EXT-X-KEY`, `EXT-X-SESSION-KEY`.
        case key
        /// `EXT-X-MAP` (initialization section).
        case map
        /// An HLS Interstitial's asset (`EXT-X-DATERANGE` `X-ASSET-URI`): a playlist.
        case interstitial
        /// An HLS Interstitial's asset list (`X-ASSET-LIST`): JSON naming more URIs.
        case assetList
        /// `EXT-X-SESSION-DATA` and any other attribute holding an http(s) URL.
        case data

        /// The request's trigger in the Network window.
        var label: String {
            switch self {
            case .playlist: "HLS playlist"
            case .segment: "HLS segment"
            case .key: "HLS key"
            case .map: "HLS init section"
            case .interstitial: "HLS interstitial"
            case .assetList: "HLS asset list"
            case .data: "HLS data"
            }
        }
    }

    /// One URI of a playlist, resolved against the playlist's own URL.
    struct Reference: Sendable, Hashable {
        var url: URL
        var kind: Kind
    }

    static let mimeTypes: Set<String> = ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"]

    /// A playlist by its MIME type, or by its first line (`#EXTM3U`, after an optional BOM and whitespace).
    static func isPlaylist(_ body: Data, mimeType: String?) -> Bool {
        if let mimeType, mimeTypes.contains(mimeType.lowercased()) { return true }
        var bytes = body.prefix(64)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0D || first == 0x0A { bytes = bytes.dropFirst() }
        return bytes.starts(with: Array("#EXTM3U".utf8))
    }

    /// `text` with every URI replaced by `route(reference)`: URI lines, the `URI`, `X-ASSET-URI` and `X-ASSET-LIST`
    /// attributes of tags, and any other quoted attribute holding an http(s) URL. Relative URIs are resolved against
    /// `base`. http(s) references are offered to `route`; one that cannot be resolved becomes `unresolved` (never left for
    /// the player to fetch itself); `data:` and other schemes stay as they are (none of them reaches the network through
    /// the player). `EXT-X-CONTENT-STEERING` is dropped: a steering manifest can swap the host of a routed URI for an
    /// origin's, and without it the player keeps the default pathway. Variables (`EXT-X-DEFINE`) are not expanded: a URI
    /// that uses one cannot be resolved, so it fails closed. Attribute values are read quoted, single-quoted or bare, with
    /// spaces around them; and any line still naming an http(s) URL after rewriting is dropped (fail closed).
    static func rewrite(_ text: String, base: URL, unresolved: String, route: (Reference) -> String) -> String {
        withoutActuallyEscaping(route) { route in
            rewriteLines(text, router: Router(base: base, unresolved: unresolved, route: route))
        }
    }

    private static func rewriteLines(_ text: String, router route: Router) -> String {
        var nextURIKind = Kind.segment
        var lines: [String] = []
        var isFirst = true
        // Any line break (LF, CRLF, which Swift reads as one Character, or CR); the output uses LF.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if isFirst, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            isFirst = false
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var produced: [String] = []
            if trimmed.hasPrefix("#EXT") {
                let tag = trimmed.prefix { $0 != ":" }
                if tag == "#EXT-X-CONTENT-STEERING" { continue }
                if tag == "#EXT-X-STREAM-INF" { nextURIKind = .playlist }
                line = rewriteAttributes(trimmed, kind: attributeKind(of: tag), route: route, produced: &produced)
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                line = route.rewritten(trimmed, kind: nextURIKind)
                produced.append(line)
                nextURIKind = .segment
            }
            // Fail closed (safety review B2): whatever syntax a line uses, if an absolute web URL is still in it once the
            // routes it was given are taken out, the player would fetch that origin itself — the line goes.
            if holdsAnOriginURL(line, besides: produced) { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Whether `line`, without the route URLs it was given, still names an http(s) URL (any case, any syntax).
    static func holdsAnOriginURL(_ line: String, besides routes: [String]) -> Bool {
        var rest = line
        for route in routes where !route.isEmpty { rest = rest.replacingOccurrences(of: route, with: "") }
        let lowered = rest.lowercased()
        return lowered.contains("http://") || lowered.contains("https://")
    }

    private static func attributeKind(of tag: Substring) -> Kind {
        switch tag {
        case "#EXT-X-MEDIA", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-RENDITION-REPORT": .playlist
        case "#EXT-X-KEY", "#EXT-X-SESSION-KEY": .key
        case "#EXT-X-MAP": .map
        case "#EXT-X-PART", "#EXT-X-PRELOAD-HINT": .segment
        default: .data
        }
    }

    /// Resolves and routes one URI.
    private struct Router {
        let base: URL
        let unresolved: String
        let route: (Reference) -> String

        func rewritten(_ uri: String, kind: Kind) -> String {
            switch URLText.scheme(uri) {
            case "http"?, "https"?, nil:
                guard let url = URL(string: uri, relativeTo: base)?.absoluteURL ?? URLText.requestURL(uri),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return unresolved }
                return route(Reference(url: url, kind: kind))
            default:
                return uri
            }
        }
    }

    /// Rewrites the `URI` and `SERVER-URI` attributes of one tag line, and any other attribute holding an http(s) URL;
    /// everything else is kept byte for byte. `produced` collects the routes written in.
    private static func rewriteAttributes(_ line: String, kind: Kind, route: Router, produced: inout [String]) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        var output = String(line[...colon])
        var index = line.index(after: colon)
        var attributeStart = index
        var quote: Character?
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                output += rewriteAttribute(line[attributeStart..<index], kind: kind, route: route, produced: &produced) + ","
                attributeStart = line.index(after: index)
            }
            index = line.index(after: index)
        }
        output += rewriteAttribute(line[attributeStart...], kind: kind, route: route, produced: &produced)
        return output
    }

    /// One `NAME=value` attribute: the value may be double-quoted (the spec's form), single-quoted or bare, with spaces
    /// around it (safety review B2: AVFoundation reads those too). A rewritten value is written back in the canonical
    /// quoted form.
    private static func rewriteAttribute(_ attribute: Substring, kind: Kind, route: Router, produced: inout [String]) -> String {
        guard let equals = attribute.firstIndex(of: "=") else { return String(attribute) }
        let name = attribute[..<equals].trimmingCharacters(in: .whitespaces).uppercased()
        let raw = attribute[attribute.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        let uri: String
        if raw.count >= 2, let first = raw.first, first == "\"" || first == "'", raw.last == first {
            uri = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        } else if !raw.isEmpty, !raw.contains("\""), !raw.contains("'") {
            uri = raw
        } else {
            return String(attribute)
        }
        let attributeKind: Kind
        switch name {
        case "URI", "SERVER-URI": attributeKind = kind
        case "X-ASSET-URI": attributeKind = .interstitial
        case "X-ASSET-LIST": attributeKind = .assetList
        default:
            // Any other attribute that holds an absolute http(s) URL.
            guard let scheme = URLText.scheme(uri)?.lowercased(), scheme == "http" || scheme == "https" else { return String(attribute) }
            attributeKind = .data
        }
        let routed = route.rewritten(uri, kind: attributeKind)
        produced.append(routed)
        return "\(attribute[..<equals].trimmingCharacters(in: .whitespaces))=\"\(routed)\""
    }

    // MARK: Asset lists

    /// An HLS Interstitials asset list (JSON) with every URI routed: `URI` values (relative ones resolved against `base`)
    /// and any other absolute http(s) string. `nil` when `data` is not JSON.
    static func rewriteAssetList(_ data: Data, base: URL, route: (URL) -> String) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let rewritten = withoutActuallyEscaping(route) { route in rewriteJSON(object, key: nil, base: base, route: route) }
        return try? JSONSerialization.data(withJSONObject: rewritten, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }

    /// JSONSerialization refuses nesting deeper than a few hundred levels, so the recursion is bounded.
    private static func rewriteJSON(_ value: Any, key: String?, base: URL, route: (URL) -> String) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = rewriteJSON(pair.value, key: pair.key, base: base, route: route)
            }
        case let array as [Any]:
            return array.map { rewriteJSON($0, key: key, base: base, route: route) }
        case let string as String:
            let scheme = URLText.scheme(string)
            let isAbsoluteWeb = scheme == "http" || scheme == "https"
            guard isAbsoluteWeb || (key == "URI" && scheme == nil),
                  let url = URL(string: string, relativeTo: base)?.absoluteURL ?? URLText.requestURL(string),
                  let resolved = url.scheme?.lowercased(), resolved == "http" || resolved == "https" else { return string }
            return route(url)
        default:
            return value
        }
    }
}
