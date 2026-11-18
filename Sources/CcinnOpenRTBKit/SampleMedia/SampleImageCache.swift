import Foundation

/// The generated sample images on disk, least recently used first out once they take more than `limit` bytes. Only
/// images are tracked: the canonical video and audio are two fixed files and always stay.
struct SampleImageCache: Sendable {
    let limit: Int
    private(set) var totalBytes = 0
    private var entries: [String: (bytes: Int, lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    var count: Int { entries.count }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    /// Records a use of `name` (adding it with `bytes` if it is new): it becomes the most recently used.
    mutating func touch(_ name: String, bytes: Int) {
        clock &+= 1
        let size = max(0, bytes)
        if let previous = entries[name] { totalBytes -= previous.bytes }
        entries[name] = (size, clock)
        totalBytes += size
    }

    mutating func remove(_ name: String) {
        if let removed = entries.removeValue(forKey: name) { totalBytes -= removed.bytes }
    }

    /// Removes least recently used images until the total fits `limit`, never `keeping`; returns their names (the caller
    /// deletes the files).
    mutating func evict(keeping: String) -> [String] {
        var evicted: [String] = []
        while totalBytes > limit {
            guard let oldest = entries.lazy.filter({ $0.key != keeping }).min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            remove(oldest)
            evicted.append(oldest)
        }
        return evicted
    }
}
