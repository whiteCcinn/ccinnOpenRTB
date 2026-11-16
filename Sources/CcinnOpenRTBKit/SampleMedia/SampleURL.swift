import Foundation

/// A generated sample image: a named creative size or any `W×H`.
public struct SampleImageSpec: Sendable, Hashable {
    public var name: String
    public var width: Int
    public var height: Int

    public static let maxDimension = 4096

    /// The named images the built-in samples use.
    public static let named: [String: (width: Int, height: Int)] = [
        "icon": (128, 128),
        "main": (1200, 627),
        "logo": (300, 300),
        "companion": (300, 250),
        "banner": (320, 50),
        "interstitial": (320, 480),
    ]

    public init?(name: String) {
        let lowered = name.lowercased()
        if let size = Self.named[lowered] {
            self.name = lowered
            width = size.width
            height = size.height
            return
        }
        let parts = lowered.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isNumber) }),
              let width = Int(parts[0]), let height = Int(parts[1]),
              (1...Self.maxDimension).contains(width), (1...Self.maxDimension).contains(height) else { return nil }
        self.name = "\(width)x\(height)"
        self.width = width
        self.height = height
    }
}

/// What a `ccinn-sample://` URL refers to.
public enum SampleAsset: Sendable, Hashable {
    /// 15 s, 1280×720, H.264 + AAC, with a running timecode.
    case video
    /// 15 s AAC tone.
    case audio
    case image(SampleImageSpec)

    /// The cache file name.
    public var fileName: String {
        switch self {
        case .video: "sample-15s.mp4"
        case .audio: "sample-15s.m4a"
        case let .image(spec): "image-\(spec.name).png"
        }
    }

    public var mimeType: String {
        switch self {
        case .video: "video/mp4"
        case .audio: "audio/mp4"
        case .image: "image/png"
        }
    }
}

/// `ccinn-sample://media/<file>` and `ccinn-sample://image/<name>.png`: offline media the app generates locally
/// (design D11). Lenient about file names: any `.mp4`/`.m4v`/`.mov` under `media` is the sample video and any
/// `.m4a`/`.mp3`/`.aac`/`.wav` the sample audio.
public enum SampleURL {
    public static let scheme = "ccinn-sample"
    /// Canonical sample video URL (aliases: `sample-video.mp4`, any `.mp4`/`.m4v`/`.mov`).
    public static let video = "ccinn-sample://media/sample-15s.mp4"
    /// Canonical sample audio URL (aliases: `sample-audio.m4a`, any `.m4a`/`.mp3`/`.aac`/`.wav`).
    public static let audio = "ccinn-sample://media/sample-15s.m4a"

    public static func image(_ name: String) -> String { "ccinn-sample://image/\(name).png" }

    public static func isSampleURL(_ url: String) -> Bool {
        URLText.scheme(url) == scheme
    }

    public static func parse(_ url: String) -> SampleAsset? {
        let prefix = scheme + "://"
        guard url.count > prefix.count, url.prefix(prefix.count).lowercased() == prefix else { return nil }
        var rest = url.dropFirst(prefix.count)
        if let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
        let segments = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 2 else { return nil }
        let kind = segments[0].lowercased()
        let file = String(segments[1]).removingPercentEncoding ?? String(segments[1])
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension.lowercased()
        switch kind {
        case "media":
            if ["mp4", "m4v", "mov"].contains(ext) { return .video }
            if ["m4a", "mp3", "aac", "wav"].contains(ext) { return .audio }
            return nil
        case "image":
            guard ext.isEmpty || ["png", "jpg", "jpeg"].contains(ext), let spec = SampleImageSpec(name: base) else { return nil }
            return .image(spec)
        default:
            return nil
        }
    }
}

/// Resolves sample assets to local files; injectable so monitor tests need no media generation.
public protocol SampleMediaProviding: Sendable {
    func fileURL(for asset: SampleAsset) async throws -> URL
}
