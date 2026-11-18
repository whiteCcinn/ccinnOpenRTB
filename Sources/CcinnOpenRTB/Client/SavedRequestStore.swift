import Foundation

/// Saved requests on disk: one `<id>.json` per request in `directory`, off the main actor.
///
/// - The directory is created `0700` and every file written `0600`: saved requests hold endpoint credentials (headers)
///   and the request's personal data (device ids, IP, location, consent).
/// - Writes are atomic (a complete file or the previous one, never half of one).
/// - Reading never fails on content: a file that is not a saved request, does not decode or is larger than
///   `maxFileBytes` is skipped and named in `Snapshot.unreadable`. Only `.json` files are read. When two files claim one
///   id (a copied file), the most recently updated is kept.
actor SavedRequestStore {
    struct Snapshot: Sendable {
        var requests: [SavedRequest]
        /// File names that could not be read.
        var unreadable: [String]
    }

    static let defaultMaxFileBytes = 64 << 20

    /// `~/Library/Application Support/CcinnOpenRTB/Requests`.
    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("CcinnOpenRTB", isDirectory: true).appendingPathComponent("Requests", isDirectory: true)
    }

    let directory: URL
    let maxFileBytes: Int

    init(directory: URL, maxFileBytes: Int = SavedRequestStore.defaultMaxFileBytes) {
        self.directory = directory
        self.maxFileBytes = max(0, maxFileBytes)
    }

    func loadAll() throws -> Snapshot {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return Snapshot(requests: [], unreadable: []) }
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
        let decoder = SavedRequestCoding.decoder()
        var byID: [UUID: SavedRequest] = [:]
        var unreadable: [String] = []
        for file in files {
            guard let request = read(file, decoder: decoder) else {
                unreadable.append(file.lastPathComponent)
                continue
            }
            if let kept = byID[request.id], kept.updatedAt >= request.updatedAt { continue }
            byID[request.id] = request
        }
        return Snapshot(requests: Array(byID.values), unreadable: unreadable.sorted())
    }

    func write(_ request: SavedRequest) throws {
        try prepareDirectory()
        try write(request, encoder: SavedRequestCoding.encoder())
    }

    /// Writes every request (an import); returns the ids that could not be written. Throws only when the folder itself
    /// cannot be prepared.
    func write(_ requests: [SavedRequest]) throws -> Set<UUID> {
        try prepareDirectory()
        let encoder = SavedRequestCoding.encoder()
        var failed: Set<UUID> = []
        for request in requests {
            do { try write(request, encoder: encoder) } catch { failed.insert(request.id) }
        }
        return failed
    }

    private func write(_ request: SavedRequest, encoder: JSONEncoder) throws {
        let file = fileURL(for: request.id)
        try encoder.encode(request).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Removes the request's file; a request that has no file is already gone.
    func delete(id: UUID) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    // MARK: Files

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func read(_ file: URL, decoder: JSONDecoder) -> SavedRequest? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
              (values.fileSize ?? 0) <= maxFileBytes,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= maxFileBytes else { return nil }
        return try? decoder.decode(SavedRequest.self, from: data)
    }

    /// Creates the directory private to the user, and makes an existing one private again.
    private func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
