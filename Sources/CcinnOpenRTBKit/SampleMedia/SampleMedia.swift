import Foundation

/// Offline sample media, generated on first use under Caches (design D11).
///
/// - Thread-safe and idempotent: concurrent requests for the same asset share one generation task; different assets
///   generate in parallel, off the actor.
/// - Files are written in a private temporary directory and moved into place, so a half-written file is never served,
///   also across processes. The temporary directory is removed afterwards with whatever the encoder put next to its
///   output (AVAssetWriter keeps a side file there until it is torn down). A process that crashes mid-generation can't
///   remove its directory, so every instance sweeps away workspaces over an hour old when it is created. A generator
///   version is part of the directory, so a changed generator never serves stale files.
public actor SampleMedia: SampleMediaProviding {
    public static let generatorVersion = 1
    public static let shared = SampleMedia(directory: SampleMedia.defaultDirectory)

    public nonisolated let directory: URL
    private var inFlight: [String: Task<URL, any Error>] = [:]

    /// Each generation works in its own `.tmp-<UUID>` directory; earlier builds wrote `.tmp-<UUID>-<file>` files.
    static let workspacePrefix = ".tmp-"
    /// A workspace this old belongs to a generation that will never finish: one takes seconds, and the writer gives up
    /// within about two minutes. So it can be removed even while other processes are generating.
    static let staleWorkspaceAge: TimeInterval = 3_600

    /// Removes the workspaces that crashed processes left behind (`removeStaleWorkspaces`). It starts when the instance
    /// is created, off the caller's thread, because `shared` is first used on the main actor.
    nonisolated let startupSweep: Task<Void, Never>

    public init(directory: URL) {
        self.directory = directory
        startupSweep = Task.detached(priority: .utility) { Self.removeStaleWorkspaces(in: directory) }
    }

    /// Removes the entries in `directory` that are named like a workspace and were last modified more than `age` ago.
    /// Anything else stays, and so does an entry whose date can't be read. Several processes may sweep at once: an
    /// entry another one removed first is simply skipped.
    nonisolated static func removeStaleWorkspaces(in directory: URL, olderThan age: TimeInterval = staleWorkspaceAge) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return  // nothing generated here yet
        }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries where entry.lastPathComponent.hasPrefix(workspacePrefix) {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? manager.removeItem(at: entry)
        }
    }

    public nonisolated static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("io.github.whiteccinn.ccinnopenrtb", isDirectory: true)
            .appendingPathComponent("SampleMedia", isDirectory: true)
            .appendingPathComponent("v\(generatorVersion)", isDirectory: true)
    }

    /// The local file for `asset`, generating it if needed.
    public func fileURL(for asset: SampleAsset) async throws -> URL {
        let target = directory.appendingPathComponent(asset.fileName)
        if Self.isUsable(target) { return target }
        if let running = inFlight[asset.fileName] { return try await running.value }
        let directory = directory
        let task = Task { () throws -> URL in
            try await Self.offThePool { try Self.generate(asset, at: target, in: directory) }
        }
        inFlight[asset.fileName] = task
        defer { inFlight[asset.fileName] = nil }
        return try await task.value
    }

    /// The contents of `asset` (generating it if needed).
    public func data(for asset: SampleAsset) async throws -> Data {
        let file = try await fileURL(for: asset)
        return try await Task.detached(priority: .userInitiated) { try Data(contentsOf: file, options: .mappedIfSafe) }.value
    }

    /// Resolves a `ccinn-sample://` URL to its local file.
    public func fileURL(for url: String) async throws -> URL {
        guard let asset = SampleURL.parse(url) else { throw SampleMediaError.unknownSample(String(url.prefix(200))) }
        return try await fileURL(for: asset)
    }

    // MARK: Generation (off the actor and off the Swift concurrency pool)

    /// Runs blocking work (encoding waits for the writer) on a dispatch queue, not on a cooperative thread.
    private nonisolated static func offThePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private nonisolated static func isUsable(_ file: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0
    }

    private nonisolated static func generate(_ asset: SampleAsset, at target: URL, in directory: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if isUsable(target) { return target }
        let workspace = directory.appendingPathComponent("\(workspacePrefix)\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: workspace) }
        let temporary = workspace.appendingPathComponent(asset.fileName)
        switch asset {
        case let .image(spec):
            guard let data = SampleImageRenderer.png(spec) else { throw SampleMediaError.generationFailed("could not render \(spec.name)") }
            try data.write(to: temporary)
        case .video:
            try SampleMovieWriter.writeVideo(to: temporary)
        case .audio:
            try SampleMovieWriter.writeAudio(to: temporary)
        }
        do {
            try manager.moveItem(at: temporary, to: target)
        } catch where isUsable(target) {
            // Another process finished first: use its file.
        }
        guard isUsable(target) else { throw SampleMediaError.generationFailed("\(asset.fileName) is empty") }
        return target
    }
}

public enum SampleMediaError: Error, Sendable, Equatable, LocalizedError {
    case unknownSample(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownSample(url): "Unknown sample “\(url)”."
        case let .generationFailed(reason): "Could not generate the sample: \(reason)."
        }
    }
}
