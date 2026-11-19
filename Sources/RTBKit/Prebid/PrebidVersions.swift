import Foundation

/// Prebid.js releases on npm and the one a new page uses: the newest stable release at least `minimumAge` old — a release
/// a day old may carry fresh regressions, or a compromised publish (the user's choice). Pure.
public enum PrebidVersions {
    public static let minimumAge: TimeInterval = 14 * 86_400

    /// The release dates in the npm registry document's `time` map (`created` and `modified` left out); `nil` when the
    /// data is not a registry document. `time` keeps unpublished versions, so when the document lists its `versions` only
    /// those count; nothing newer than `dist-tags.latest` does (a stable-looking number published under another tag).
    public static func releaseDates(fromRegistry data: Data) -> [String: Date]? {
        guard case let .object(root)? = try? JSONValue.parse(data), case let .object(time)? = root["time"] else { return nil }
        var published: Set<String>?
        if case let .object(versions)? = root["versions"] { published = Set(versions.keys) }
        var latest: [Int]?
        if case let .object(tags)? = root["dist-tags"], case let .string(tag)? = tags["latest"] { latest = numbers(of: tag) }
        var dates: [String: Date] = [:]
        for (version, value) in time where version != "created" && version != "modified" {
            guard published?.contains(version) ?? true, case let .string(text) = value, let date = parseDate(text) else { continue }
            if let latest, let parts = numbers(of: version), latest.lexicographicallyPrecedes(parts) { continue }
            dates[version] = date
        }
        return dates
    }

    /// Stable versions (no prerelease), newest first.
    public static func stableVersions(_ releasedAt: [String: Date]) -> [String] {
        releasedAt.keys.compactMap { version in numbers(of: version).map { (version, $0) } }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) == false && $0.1 != $1.1 }
            .map(\.0)
    }

    /// The newest stable version released at least `minimumAge` before `now`.
    public static func defaultVersion(releasedAt: [String: Date], now: Date, minimumAge: TimeInterval = minimumAge) -> String? {
        stableVersions(releasedAt).first { version in releasedAt[version].map { now.timeIntervalSince($0) >= minimumAge } ?? false }
    }

    /// `[major, minor, patch]` of a stable semantic version; `nil` for a prerelease or anything else.
    static func numbers(of version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        return numbers.count == 3 ? numbers : nil
    }

    private static func parseDate(_ text: String) -> Date? {
        (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(text, strategy: .iso8601))
    }
}
