import CcinnOpenRTBKit
import Foundation
import Observation

/// The saved requests every main window sees (`shared`), newest first. Every change is written through
/// `SavedRequestStore` before the list shows it, so the list is what is on disk; a failed write leaves the list as it
/// was and says why in `lastError`.
@MainActor
@Observable
final class SavedRequestLibrary {
    static let shared = SavedRequestLibrary(store: SavedRequestStore(directory: SavedRequestStore.defaultDirectory))

    /// Most recently updated first (then by name).
    private(set) var requests: [SavedRequest] = []
    /// Files in the folder that could not be read (skipped).
    private(set) var unreadableFiles: [String] = []
    private(set) var isLoaded = false
    private(set) var lastError: String?
    /// The outcome of the last export or import, for the user.
    private(set) var lastNotice: String?

    @ObservationIgnored let store: SavedRequestStore
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(store: SavedRequestStore, now: @escaping @MainActor () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    var directory: URL { store.directory }

    func request(id: UUID) -> SavedRequest? { requests.first { $0.id == id } }

    /// Reads the folder once; concurrent callers share that read.
    func loadIfNeeded() async {
        if isLoaded { return }
        if let loading {
            await loading.value
            return
        }
        let task = Task { await self.reload() }
        loading = task
        await task.value
        loading = nil
    }

    /// Reads the folder again (another app or a Finder copy may have changed it).
    func reload() async {
        do {
            let snapshot = try await store.loadAll()
            requests = Self.sorted(snapshot.requests)
            unreadableFiles = snapshot.unreadable
            lastError = nil
        } catch {
            lastError = "The saved requests could not be read: \(error.localizedDescription)"
        }
        isLoaded = true
    }

    /// Writes `request` (new, or replacing the one with its id). `false` when it could not be written.
    @discardableResult
    func save(_ request: SavedRequest) async -> Bool {
        await loadIfNeeded()
        do {
            try await store.write(request)
        } catch {
            lastError = "“\(request.name)” could not be saved: \(error.localizedDescription)"
            return false
        }
        requests.removeAll { $0.id == request.id }
        requests = Self.sorted(requests + [request])
        lastError = nil
        lastNotice = nil
        return true
    }

    /// Deletes the request from disk and the list; `false` (with `lastError`, the request still listed) when it could not.
    @discardableResult
    func delete(_ id: UUID) async -> Bool {
        await loadIfNeeded()
        do {
            try await store.delete(id: id)
        } catch {
            lastError = "The request could not be deleted: \(error.localizedDescription)"
            return false
        }
        requests.removeAll { $0.id == id }
        lastError = nil
        lastNotice = nil
        return true
    }

    /// A copy named "<name> copy", saved as a new request.
    func duplicate(_ id: UUID) async -> SavedRequest? {
        await loadIfNeeded()
        guard let original = request(id: id) else { return nil }
        let date = now()
        let copy = SavedRequest(id: UUID(), name: original.name + " copy", createdAt: date, updatedAt: date, request: original.request,
                                exchange: original.exchange)
        return await save(copy) ? copy : nil
    }

    // MARK: Export and import

    /// What an import did. Requests are merged by id: a request already here is replaced only by a more recently updated
    /// copy, so importing the same file again changes nothing and never loses newer work.
    struct ImportResult: Equatable, Sendable {
        var added = 0
        var updated = 0
        /// Already here, as recent or more recent.
        var unchanged = 0
        /// Entries of the file that could not be read.
        var unreadable = 0
        /// Requests that could not be written.
        var failed = 0
    }

    /// Every saved request as one archive (`SavedRequestArchive`), encoded off the main actor; `nil` (with
    /// `lastError`) when it cannot be encoded.
    func exportArchive(appVersion: String = AppInfo.version) async -> Data? {
        await loadIfNeeded()
        let snapshot = requests
        let date = now()
        do {
            return try await Task.detached(priority: .userInitiated) {
                try SavedRequestArchive.encode(snapshot, exportedAt: date, appVersion: appVersion)
            }.value
        } catch {
            lastError = "The saved requests could not be exported: \(error.localizedDescription)"
            return nil
        }
    }

    /// Writes the archive to `url`, readable only by the user (it holds the requests' headers and personal data).
    func exportArchive(to url: URL, appVersion: String = AppInfo.version) async throws {
        guard let data = await exportArchive(appVersion: appVersion) else { throw CocoaError(.fileWriteUnknown) }
        let count = requests.count
        do {
            try await Task.detached(priority: .userInitiated) { try Self.writePrivately(data, to: url) }.value
        } catch {
            lastError = "The export could not be written: \(error.localizedDescription)"
            throw error
        }
        lastError = nil
        lastNotice = "Exported \(Self.count(count, "request"))."
    }

    /// Imports an archive (or a single saved-request file) in one go, merged by id (see `ImportResult`). A file that is
    /// not an export changes nothing.
    @discardableResult
    func importArchive(_ data: Data) async throws(SavedRequestArchive.Failure) -> ImportResult {
        await loadIfNeeded()
        let decoded = await Task.detached(priority: .userInitiated) { () -> Result<SavedRequestArchive.Decoded, SavedRequestArchive.Failure> in
            Result { () throws(SavedRequestArchive.Failure) in try SavedRequestArchive.decode(data) }
        }.value
        let archive = try decoded.get()
        // One request per id: the archive's most recently updated copy.
        var newest: [UUID: SavedRequest] = [:]
        for request in archive.requests {
            if let kept = newest[request.id], !SavedRequestCoding.isNewer(request.updatedAt, than: kept.updatedAt) { continue }
            newest[request.id] = request
        }
        var result = ImportResult(unreadable: archive.unreadable)
        var accepted: [SavedRequest] = []
        for incoming in newest.values {
            if let existing = request(id: incoming.id), !SavedRequestCoding.isNewer(incoming.updatedAt, than: existing.updatedAt) {
                result.unchanged += 1
            } else {
                accepted.append(incoming)
            }
        }
        let failed: Set<UUID>
        do {
            failed = try await store.write(accepted)
        } catch {
            failed = Set(accepted.map(\.id))
        }
        var byID = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for incoming in accepted where !failed.contains(incoming.id) {
            if byID[incoming.id] == nil { result.added += 1 } else { result.updated += 1 }
            byID[incoming.id] = incoming
        }
        result.failed = failed.count
        requests = Self.sorted(Array(byID.values))
        lastError = failed.isEmpty ? nil : "\(Self.count(failed.count, "request")) could not be written to the Requests folder."
        lastNotice = Self.notice(for: result)
        return result
    }

    /// Reads `url` (refusing a file over `SavedRequestArchive.defaultMaxBytes` before reading it) and imports it; a
    /// failure is also left in `lastError`.
    @discardableResult
    func importArchive(contentsOf url: URL) async throws(SavedRequestArchive.Failure) -> ImportResult {
        let read = await Task.detached(priority: .userInitiated) { () -> Result<Data, SavedRequestArchive.Failure> in
            Self.readArchiveFile(url)
        }.value
        do {
            return try await importArchive(try read.get())
        } catch {
            lastError = error.message
            lastNotice = nil
            throw error
        }
    }

    nonisolated private static func readArchiveFile(_ url: URL) -> Result<Data, SavedRequestArchive.Failure> {
        let limit = SavedRequestArchive.defaultMaxBytes
        do {
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { return .failure(.tooLarge(limit: limit)) }
            return .success(try Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            return .failure(.unreadableFile(error.localizedDescription))
        }
    }

    static func notice(for result: ImportResult) -> String {
        var sentences: [String] = []
        let imported = result.added + result.updated
        if imported == 0 {
            sentences.append(result.unchanged == 0 ? "Nothing to import."
                : "Nothing new: \(count(result.unchanged, "request")) \(result.unchanged == 1 ? "is" : "are") already here.")
        } else {
            var sentence = "Imported \(count(imported, "request"))"
            if result.updated > 0 { sentence += " (\(result.updated) replacing an older copy)" }
            if result.unchanged > 0 { sentence += "; \(result.unchanged) already here" }
            sentences.append(sentence + ".")
        }
        if result.unreadable > 0 { sentences.append("\(count(result.unreadable, "entry", plural: "entries")) of the file could not be read.") }
        if result.failed > 0 { sentences.append("\(count(result.failed, "request")) could not be saved.") }
        return sentences.joined(separator: " ")
    }

    private static func count(_ value: Int, _ noun: String, plural: String? = nil) -> String {
        "\(value) " + (value == 1 ? noun : plural ?? noun + "s")
    }

    /// Creates (or replaces) `url` with `data`, permissions 0600 from the start.
    nonisolated private static func writePrivately(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: url)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private static func sorted(_ requests: [SavedRequest]) -> [SavedRequest] {
        requests.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
