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
        let decoder = Self.decoder()
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
        let file = fileURL(for: request.id)
        try Self.encoder().encode(request).write(to: file, options: [.atomic])
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

    /// ISO 8601 with milliseconds: readable, and ordered within a second.
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Pretty-printed with sorted keys: a saved request reads and diffs well as a file.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }

    /// Reads dates with or without fractional seconds (a hand-edited file).
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = (try? Date(text, strategy: dateStyle)) ?? (try? Date(text, strategy: .iso8601)) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text.prefix(40))")
        }
        return decoder
    }
}
