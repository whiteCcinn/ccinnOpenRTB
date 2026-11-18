import Foundation
import os

/// The temporary files `prepareMedia` writes for `data:` media (AVPlayer needs a file URL), in one directory of their
/// own. A store deletes the files it wrote when the render ends (`removeAll`), when there are more than `maxFiles`
/// (oldest first), and when it is released. Files a quit or crashed process left behind are swept by every new store
/// once they are over `staleAge` old, which no render reaches; another window's files in use are younger.
final class MediaTemporaryFiles: Sendable {
    static let filePrefix = "ccinn-media-"
    /// A render plays its pod's media one at a time; more files than this are a leak, not a render.
    static let maxFiles = 8
    static let staleAge: TimeInterval = 3_600

    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("io.github.whiteccinn.ccinnopenrtb", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
    }

    let directory: URL
    /// Removes stale files; starts when the store is created, off the caller's thread.
    let startupSweep: Task<Void, Never>
    /// The files this store wrote, oldest first.
    private let files = OSAllocatedUnfairLock(initialState: [URL]())

    init(directory: URL = MediaTemporaryFiles.defaultDirectory) {
        self.directory = directory
        startupSweep = Task.detached(priority: .utility) { Self.removeStaleFiles(in: directory) }
    }

    deinit {
        removeAll()
    }

    /// Writes `data` to a new file (off the caller's thread) and returns it.
    func write(_ data: Data, mimeType: String) async throws -> URL {
        let directory = directory
        let file = directory.appendingPathComponent("\(Self.filePrefix)\(UUID().uuidString).\(Self.fileExtension(for: mimeType))")
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }.value
        let surplus = files.withLock { files -> [URL] in
            files.append(file)
            guard files.count > Self.maxFiles else { return [] }
            let surplus = Array(files.prefix(files.count - Self.maxFiles))
            files.removeFirst(surplus.count)
            return surplus
        }
        for old in surplus { try? FileManager.default.removeItem(at: old) }
        return file
    }

    /// Deletes every file this store wrote.
    func removeAll() {
        let written = files.withLock { files -> [URL] in
            defer { files.removeAll() }
            return files
        }
        for file in written { try? FileManager.default.removeItem(at: file) }
    }

    /// Removes this store's kind of file in `directory` last modified over `age` ago; anything else stays.
    static func removeStaleFiles(in directory: URL, olderThan age: TimeInterval = staleAge) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries where entry.lastPathComponent.hasPrefix(filePrefix) {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? manager.removeItem(at: entry)
        }
    }

    static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "audio/mp4", "audio/x-m4a", "audio/aac": "m4a"
        case "audio/mpeg", "audio/mp3": "mp3"
        case "application/x-mpegurl", "application/vnd.apple.mpegurl": "m3u8"
        case "video/webm": "webm"
        default: "bin"
        }
    }
}
