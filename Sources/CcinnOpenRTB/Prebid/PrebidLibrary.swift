import CcinnOpenRTBKit
import Foundation
import RTBKit

/// Prebid.js files of a version — the loader, its chunks, the module metadata — fetched from the npm package on jsDelivr
/// through the window's network monitor (content: recorded, sent in Simulated and Real mode, not when Offline) and kept
/// in the cache, so a version once loaded also runs Offline. The page's script `integrity` (Prebid's own SHA-256 manifest)
/// checks every chunk; the loader's embedded hash checks the manifest.
///
/// Only `dist/…` and `metadata/…` files of a version written as digits and dots are served, and the page gets scripts
/// only from the `dist/` of the version it runs: it cannot make the app fetch anything else.
@MainActor
final class PrebidLibrary {
    static let jsDelivrBase = "https://cdn.jsdelivr.net/npm/prebid.js@"
    static let registryURL = "https://registry.npmjs.org/prebid.js"

    let cacheDirectory: URL
    private let upstreamBase: String
    private let registry: String
    private let monitor: @MainActor () -> NetworkMonitor
    private let userAgent: @MainActor () -> String

    init(cacheDirectory: URL = PrebidLibrary.defaultCacheDirectory, upstreamBase: String = PrebidLibrary.jsDelivrBase,
         registry: String = PrebidLibrary.registryURL, monitor: @escaping @MainActor () -> NetworkMonitor,
         userAgent: @escaping @MainActor () -> String) {
        self.cacheDirectory = cacheDirectory
        self.upstreamBase = upstreamBase
        self.registry = registry
        self.monitor = monitor
        self.userAgent = userAgent
    }

    static var defaultCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("CcinnOpenRTB/prebid", isDirectory: true)
    }

    enum Failure: Error, Equatable, LocalizedError {
        case invalidPath(String)
        /// A script that is not a file of the page's Prebid.js.
        case notPrebid(String)
        /// The registry answered something that lists no version.
        case unreadableRegistry

        var errorDescription: String? {
            switch self {
            case let .invalidPath(path): "Not a Prebid.js file: \(path.prefix(200))"
            case let .notPrebid(url): "Not a script of this Prebid.js: \(url.prefix(200))"
            case .unreadableRegistry: "The npm registry did not list the Prebid.js versions."
            }
        }
    }

    /// Where `version`'s `dist/` lives upstream: the page loads its scripts from there, by these URLs.
    func distBase(version: String) -> String {
        upstreamBase + version + "/dist/"
    }

    /// The script at `url`, which must be a `dist/` file of `version` (its query, such as the loader's `?modules=` or the
    /// manifest's `?callback=`, is the page's business).
    func script(at url: String, version: String) async throws -> Data {
        guard Self.isValid(version: version), var components = URLComponents(string: url) else { throw Failure.notPrebid(url) }
        components.query = nil
        components.fragment = nil
        let base = distBase(version: version)
        guard let bare = components.string, bare.hasPrefix(base), bare.count > base.count else { throw Failure.notPrebid(url) }
        return try await file(version: version, path: "dist/" + bare.dropFirst(base.count))
    }

    static func isValid(version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// `dist/…` or `metadata/…`, made of plain file-name components.
    static func isValid(path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2, components.first == "dist" || components.first == "metadata" else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
        }
    }

    /// The file at `path` of `version`: from the cache, else fetched through the monitor and cached.
    func file(version: String, path: String) async throws -> Data {
        guard Self.isValid(version: version), Self.isValid(path: path) else { throw Failure.invalidPath("\(version)/\(path)") }
        let cached = cacheDirectory.appendingPathComponent(version, isDirectory: true).appendingPathComponent(path)
        if let data = try? Data(contentsOf: cached) { return data }
        let (data, _) = try await monitor().fetchContent(upstreamBase + version + "/" + path, category: .content, trigger: "Prebid.js \(path)",
                                                         source: "prebid › library \(version)", parentID: nil, userAgent: userAgent())
        try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
        return data
    }

    /// Release dates of every version (the npm registry), for the version picker and its default. The last good answer
    /// is kept, so the list is there Offline, or when the registry answers something else.
    func releaseDates() async throws -> [String: Date] {
        let kept = cacheDirectory.appendingPathComponent("registry.json")
        do {
            let (data, _) = try await monitor().fetchContent(registry, category: .content, trigger: "Prebid.js versions",
                                                             source: "prebid › npm registry", parentID: nil, userAgent: userAgent())
            guard let dates = PrebidVersions.releaseDates(fromRegistry: data), !dates.isEmpty else { throw Failure.unreadableRegistry }
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: kept, options: .atomic)
            return dates
        } catch {
            if let data = try? Data(contentsOf: kept), let dates = PrebidVersions.releaseDates(fromRegistry: data), !dates.isEmpty { return dates }
            throw error
        }
    }

    /// The bidders `version` offers (with aliases), from its aggregate module metadata.
    func catalog(version: String) async throws -> [PrebidBidder] {
        PrebidCatalog.bidders(fromMetadata: try await file(version: version, path: "metadata/modules.json"))
    }
}
