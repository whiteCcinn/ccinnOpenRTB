import Foundation

/// Picks the media file to play (design D6). Owner: kit-vast.
///
/// What AVPlayer can play decides eligibility; preference follows what a mobile/CTV player does:
/// 1. Video: progressive MP4 with H.264 (or no codec given), then HLS, then other playable files (HEVC MP4, QuickTime,
///    3GPP), then audio-only files. WebM, Ogg, Flash, DASH and VPAID (JavaScript) are never chosen.
/// 2. Within the best tier, the smallest file that covers the player (width and height ≥ the player's); when none does, the
///    largest. Equal sizes: the higher bitrate (`bitrate`, else `maxBitrate`, else `minBitrate`), then document order.
/// 3. Audio (`audioOnly`): `audio/*` files (and audio HLS), highest bitrate first.
///
/// Nothing eligible: `.unsupported(.vpaidError)` (901) when every file is VPAID, otherwise `.unsupported(.noSupportedMedia)`
/// (403).
public enum VASTMediaSelector {
    public enum Choice: Sendable, Hashable {
        case play(VASTMediaFile)
        case unsupported(VASTErrorCode)
    }

    /// `playerWidth` / `playerHeight` are the player's size in the same unit as the `MediaFile` attributes (pixels); a
    /// non-positive size means unknown and picks the largest file.
    public static func choose(_ files: [VASTMediaFile], playerWidth: Int, playerHeight: Int, audioOnly: Bool = false) -> Choice {
        var candidates: [Candidate] = []
        var allVPAID = !files.isEmpty
        for (index, file) in files.enumerated() {
            let kind = VASTMediaKind(file)
            if kind != .vpaid { allVPAID = false }
            if let tier = tier(of: kind, audioOnly: audioOnly) {
                candidates.append(Candidate(file: file, tier: tier, index: index))
            }
        }
        guard let bestTier = candidates.map(\.tier).min() else {
            return .unsupported(allVPAID ? .vpaidError : .noSupportedMedia)
        }
        let best = candidates.filter { $0.tier == bestTier }
        let chosen = audioOnly ? best.max(by: Candidate.lowerBitrate) : bestFit(best, playerWidth: playerWidth, playerHeight: playerHeight)
        guard let chosen else { return .unsupported(.noSupportedMedia) }
        return .play(chosen.file)
    }

    // MARK: - Private

    private struct Candidate {
        var file: VASTMediaFile
        var tier: Int
        var index: Int

        var width: Int { max(file.width ?? 0, 0) }
        var height: Int { max(file.height ?? 0, 0) }
        var area: Int { width.multipliedReportingOverflow(by: height).overflow ? Int.max : width * height }
        var bitrate: Int { max(file.bitrate ?? file.maxBitrate ?? file.minBitrate ?? 0, 0) }

        /// Orders by bitrate, then prefers the earlier file (so `max` returns the first of equals).
        static func lowerBitrate(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            lhs.bitrate != rhs.bitrate ? lhs.bitrate < rhs.bitrate : lhs.index > rhs.index
        }
    }

    private static func tier(of kind: VASTMediaKind, audioOnly: Bool) -> Int? {
        if audioOnly {
            switch kind {
            case .audio: return 0
            case .hls(audio: true): return 1
            default: return nil
            }
        }
        switch kind {
        case .progressiveH264: return 0
        case .hls: return 1
        case .progressiveOther: return 2
        case .audio: return 3
        case .vpaid, .unsupported: return nil
        }
    }

    private static func bestFit(_ candidates: [Candidate], playerWidth: Int, playerHeight: Int) -> Candidate? {
        let covering = playerWidth > 0 && playerHeight > 0
            ? candidates.filter { $0.width >= playerWidth && $0.height >= playerHeight }
            : []
        if !covering.isEmpty {
            // Smallest covering file; equal sizes: higher bitrate, then document order.
            return covering.min { lhs, rhs in
                if lhs.area != rhs.area { return lhs.area < rhs.area }
                return Candidate.lowerBitrate(rhs, lhs)
            }
        }
        return candidates.max { lhs, rhs in
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            return Candidate.lowerBitrate(lhs, rhs)
        }
    }
}

/// What a `MediaFile` is, as far as playback is concerned.
enum VASTMediaKind: Hashable {
    case progressiveH264
    case progressiveOther
    case hls(audio: Bool)
    case audio
    /// VPAID (any `apiFramework` naming VPAID, or JavaScript media): error 901.
    case vpaid
    case unsupported

    init(_ file: VASTMediaFile) {
        if let api = file.apiFramework?.lowercased(), api.contains("vpaid") {
            self = .vpaid
            return
        }
        guard Self.isPlayableScheme(file.url) else {
            self = .unsupported
            return
        }
        let type = Self.normalizedType(file.type) ?? Self.inferredType(fromURL: file.url)
        switch type {
        case "video/mp4", "video/x-m4v", "video/m4v":
            self = Self.codecKind(file.codec)
        case "video/quicktime", "video/3gpp", "video/3gpp2":
            self = Self.codecKind(file.codec) == .unsupported ? .unsupported : .progressiveOther
        case "application/x-mpegurl", "application/vnd.apple.mpegurl", "video/mpegurl", "video/x-mpegurl":
            self = .hls(audio: false)
        case "audio/mpegurl", "audio/x-mpegurl":
            self = .hls(audio: true)
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac", "audio/x-aac", "audio/mpeg", "audio/mp3", "audio/x-mp3",
             "audio/wav", "audio/x-wav", "audio/wave", "audio/aiff", "audio/x-aiff":
            self = .audio
        case "application/javascript", "application/x-javascript", "text/javascript":
            self = .vpaid
        default:
            self = .unsupported
        }
    }

    /// Lower-cased MIME type without parameters (`video/mp4; codecs=…` → `video/mp4`).
    static func normalizedType(_ type: String?) -> String? {
        guard let type else { return nil }
        let base = type.split(separator: ";", maxSplits: 1).first.map(String.init) ?? type
        let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A type from the URL's path extension, for files that omit `type` (invalid, but common).
    static func inferredType(fromURL url: String) -> String? {
        let path = url.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? url
        guard let dot = path.lastIndex(of: "."), path[dot...].count <= 6 else { return nil }
        switch path[path.index(after: dot)...].lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m3u8": return "application/x-mpegurl"
        case "m4a", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "js": return "application/javascript"
        default: return nil
        }
    }

    /// `codec` (RFC 6381 list or a plain name) → the tier of an MP4 file.
    private static func codecKind(_ codec: String?) -> VASTMediaKind {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return .progressiveH264 }
        let parts = codec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let video = parts.filter { !$0.hasPrefix("mp4a") && !$0.hasPrefix("ac-3") && !$0.hasPrefix("ec-3") && !$0.hasPrefix("opus") }
        guard let first = video.first else { return .progressiveH264 }
        if first.hasPrefix("avc") || first.contains("264") { return .progressiveH264 }
        if first.hasPrefix("hvc") || first.hasPrefix("hev") || first.contains("265") || first.contains("hevc") { return .progressiveOther }
        if first.hasPrefix("vp") || first.hasPrefix("av01") || first.contains("theora") { return .unsupported }
        return .progressiveOther
    }

    /// AVPlayer loads http(s), files, and the simulator's `data:` / `ccinn-sample:` URLs (made local by the network layer).
    private static func isPlayableScheme(_ url: String) -> Bool {
        switch VASTURLCheck.scheme(of: url) {
        case "http", "https", "file", "data", VASTURLCheck.sampleScheme: true
        default: false
        }
    }
}
