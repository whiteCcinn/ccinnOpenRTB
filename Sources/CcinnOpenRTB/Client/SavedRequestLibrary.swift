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
        return true
    }

    func delete(_ id: UUID) async {
        await loadIfNeeded()
        do {
            try await store.delete(id: id)
            requests.removeAll { $0.id == id }
            lastError = nil
        } catch {
            lastError = "The request could not be deleted: \(error.localizedDescription)"
        }
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

    private static func sorted(_ requests: [SavedRequest]) -> [SavedRequest] {
        requests.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
