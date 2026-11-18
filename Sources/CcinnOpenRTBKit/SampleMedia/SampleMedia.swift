import Foundation

/// Offline sample media, generated on first use under Caches (design D11).
///
/// - Thread-safe and idempotent: concurrent requests for the same asset share one generation task, off the actor.
/// - A creative can ask for any `<W>x<H>` image (up to 1920×1920), so images are bounded three ways: they generate one
///   at a time (a serial queue), at most `maxImageGenerations` (32) new ones per `imageGenerationWindow` (a minute; a
///   render needs a handful, cached ones are free, a request over the limit fails with `rateLimited`), and the
///   generated images are an LRU cache of at most `maxCachedImageBytes` (64 MiB). The canonical video and audio are
///   two fixed files, generated once and never evicted.
/// - Files are written in a private temporary directory and moved into place, so a half-written file is never served,
///   also across processes. The temporary directory is removed afterwards with whatever the encoder put next to its
///   output (AVAssetWriter keeps a side file there until it is torn down). A process that crashes mid-generation can't
///   remove its directory, so every instance sweeps away workspaces over an hour old when it is created. A generator
///   version is part of the directory, so a changed generator never serves stale files.
public actor SampleMedia: SampleMediaProviding {
    public static let generatorVersion = 1
    public static let shared = SampleMedia(directory: SampleMedia.defaultDirectory)

    /// The generated images kept on disk, least recently used first out.
    public static let maxCachedImageBytes = 64 << 20
    /// New image generations allowed per `imageGenerationWindow`.
    public static let maxImageGenerations = 32
    public static let imageGenerationWindow: Duration = .seconds(60)

    public nonisolated let directory: URL
    private var inFlight: [String: Task<URL, any Error>] = [:]
    private let maxGenerations: Int
    private let generationWindow: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let imageRenderer: @Sendable (SampleImageSpec) -> Data?
    /// Image generations run here, one at a time.
    private nonisolated let imageQueue = DispatchQueue(label: "io.github.whiteccinn.ccinnopenrtb.sample-images", qos: .userInitiated)
    /// When the recent image generations started (within `generationWindow`).
    private var recentGenerations: [ContinuousClock.Instant] = []
    /// Seeded from the directory on first use.
    private var imageCache: SampleImageCache
    private var imageCacheSeeded = false

    /// Each generation works in its own `.tmp-<UUID>` directory; earlier builds wrote `.tmp-<UUID>-<file>` files.
    static let workspacePrefix = ".tmp-"
    /// A workspace this old belongs to a generation that will never finish: one takes seconds, and the writer gives up
    /// within about two minutes. So it can be removed even while other processes are generating.
    static let staleWorkspaceAge: TimeInterval = 3_600

    /// Removes the workspaces that crashed processes left behind (`removeStaleWorkspaces`). It starts when the instance
    /// is created, off the caller's thread, because `shared` is first used on the main actor.
    nonisolated let startupSweep: Task<Void, Never>

    public init(directory: URL) {
        self.init(directory: directory, imageCacheLimit: Self.maxCachedImageBytes)
    }

    /// Tests inject the limits, the clock and the image renderer.
    init(directory: URL, imageCacheLimit: Int = SampleMedia.maxCachedImageBytes, maxImageGenerations: Int = SampleMedia.maxImageGenerations,
         generationWindow: Duration = SampleMedia.imageGenerationWindow, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         imageRenderer: @escaping @Sendable (SampleImageSpec) -> Data? = SampleImageRenderer.png) {
        self.directory = directory
        imageCache = SampleImageCache(limit: imageCacheLimit)
        maxGenerations = max(0, maxImageGenerations)
        self.generationWindow = generationWindow
        self.now = now
        self.imageRenderer = imageRenderer
        startupSweep = Task.detached(priority: .utility) { Self.removeStaleWorkspaces(in: directory) }
    }

    /// Bytes of generated images on disk, as far as this instance knows.
    var cachedImageBytes: Int { imageCache.totalBytes }

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
        if let size = Self.usableSize(target) {
            if case .image = asset { useImage(asset.fileName, bytes: size, at: target) }
            return target
        }
        if let running = inFlight[asset.fileName] { return try await running.value }
        let directory = directory
        let queue: DispatchQueue
        if case .image = asset {
            try admitImageGeneration()
            queue = imageQueue
        } else {
            queue = .global(qos: .userInitiated)
        }
        let render = imageRenderer
        let task = Task { () throws -> URL in
            try await Self.offThePool(queue) { try Self.generate(asset, at: target, in: directory, render: render) }
        }
        inFlight[asset.fileName] = task
        defer { inFlight[asset.fileName] = nil }
        let file = try await task.value
        if case .image = asset { useImage(asset.fileName, bytes: Self.usableSize(file) ?? 0, at: file) }
        return file
    }

    // MARK: Image limits

    /// Counts a new image generation, or refuses it once `maxGenerations` started within `generationWindow`.
    private func admitImageGeneration() throws {
        let current = now()
        recentGenerations.removeAll { $0.duration(to: current) >= generationWindow }
        guard recentGenerations.count < maxGenerations else {
            throw SampleMediaError.rateLimited(limit: maxGenerations, window: generationWindow)
        }
        recentGenerations.append(current)
    }

    /// Records a use of a generated image and deletes the least recently used ones beyond the cap.
    private func useImage(_ name: String, bytes: Int, at file: URL) {
        seedImageCacheIfNeeded()
        imageCache.touch(name, bytes: bytes)
        // The modification date orders the cache across launches.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        for evicted in imageCache.evict(keeping: name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(evicted))
        }
    }

    /// Adds the images earlier launches left, oldest first, so they count towards the cap.
    private func seedImageCacheIfNeeded() {
        guard !imageCacheSeeded else { return }
        imageCacheSeeded = true
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let images = files.compactMap { file -> (name: String, modified: Date, bytes: Int)? in
            let name = file.lastPathComponent
            guard name.hasPrefix(SampleAsset.imageFilePrefix), name.hasSuffix(".png"),
                  let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (name, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        for image in images.sorted(by: { $0.modified < $1.modified }) where !imageCache.contains(image.name) {
            imageCache.touch(image.name, bytes: image.bytes)
        }
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
    private nonisolated static func offThePool<T: Sendable>(_ queue: DispatchQueue, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// The size of a non-empty file; `nil` when it is missing or empty.
    private nonisolated static func usableSize(_ file: URL) -> Int? {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0 ? size : nil
    }

    private nonisolated static func isUsable(_ file: URL) -> Bool {
        usableSize(file) != nil
    }

    private nonisolated static func generate(_ asset: SampleAsset, at target: URL, in directory: URL,
                                             render: @Sendable (SampleImageSpec) -> Data?) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if isUsable(target) { return target }
        let workspace = directory.appendingPathComponent("\(workspacePrefix)\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: workspace) }
        let temporary = workspace.appendingPathComponent(asset.fileName)
        switch asset {
        case let .image(spec):
            guard let data = render(spec) else { throw SampleMediaError.generationFailed("could not render \(spec.name)") }
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
    /// More than `limit` new sample images were asked for within `window`.
    case rateLimited(limit: Int, window: Duration)

    public var errorDescription: String? {
        switch self {
        case let .unknownSample(url): "Unknown sample “\(url)”."
        case let .generationFailed(reason): "Could not generate the sample: \(reason)."
        case let .rateLimited(limit, window):
            "Too many sample images: at most \(limit) new sizes per \(window.components.seconds) s are generated. Reuse a size, or try again later."
        }
    }
}
