import Foundation

/// The monitor's ordered, capped entry store (design D9).
///
/// - Sequences are assigned here, contiguous and increasing, so an entry's position is `sequence - base`: O(1) lookup.
/// - The oldest entries are dropped once `capacity` is exceeded (FIFO). Dropping only advances `head`; the array is
///   compacted in bulk, so appends stay amortised O(1) at the cap.
/// - Relationships stay sane: when a parent is dropped, its remaining children become roots (their `parentID` is
///   cleared), so no entry ever points at a parent that is gone.
struct NetworkLog: Sendable {
    let capacity: Int
    private var storage: [NetworkEntry] = []
    private var head = 0
    private var nextSequence = 1
    private var sequenceByID: [UUID: Int] = [:]
    private var childrenByParent: [UUID: [UUID]] = [:]

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    /// The live entries in sequence order.
    var entries: [NetworkEntry] { Array(storage[head...]) }

    func contains(_ id: UUID) -> Bool { index(of: id) != nil }

    func entry(_ id: UUID) -> NetworkEntry? {
        index(of: id).map { storage[$0] }
    }

    /// Live children of `id`, in sequence order.
    func children(of id: UUID) -> [NetworkEntry] {
        (childrenByParent[id] ?? []).compactMap(entry)
    }

    /// Appends `entry` with the next sequence. A duplicate id gets a fresh one. Returns the stored entry.
    @discardableResult
    mutating func append(_ entry: NetworkEntry) -> NetworkEntry {
        var entry = entry
        if sequenceByID[entry.id] != nil { entry.id = UUID() }
        if entry.parentID == entry.id { entry.parentID = nil }
        entry.sequence = nextSequence
        nextSequence += 1
        storage.append(entry)
        sequenceByID[entry.id] = entry.sequence
        if let parent = entry.parentID { childrenByParent[parent, default: []].append(entry.id) }
        while count > capacity { evictOldest() }
        return entry
    }

    /// Changes a live entry in place; `false` if it is gone (dropped or cleared). Identity fields are kept.
    @discardableResult
    mutating func update(_ id: UUID, _ change: (inout NetworkEntry) -> Void) -> Bool {
        guard let index = index(of: id) else { return false }
        var entry = storage[index]
        change(&entry)
        entry.id = storage[index].id
        entry.sequence = storage[index].sequence
        entry.parentID = storage[index].parentID
        storage[index] = entry
        return true
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        head = 0
        nextSequence = 1
        sequenceByID.removeAll()
        childrenByParent.removeAll()
    }

    private func index(of id: UUID) -> Int? {
        guard let sequence = sequenceByID[id], let base = storage.first?.sequence else { return nil }
        let index = sequence - base
        guard index >= head, index < storage.count else { return nil }
        return index
    }

    private mutating func evictOldest() {
        guard head < storage.count else { return }
        let evicted = storage[head]
        head += 1
        sequenceByID[evicted.id] = nil
        if let parent = evicted.parentID, var siblings = childrenByParent[parent] {
            if siblings.first == evicted.id { siblings.removeFirst() } else { siblings.removeAll { $0 == evicted.id } }
            childrenByParent[parent] = siblings.isEmpty ? nil : siblings
        }
        if let orphans = childrenByParent.removeValue(forKey: evicted.id) {
            for orphan in orphans {
                guard let index = index(of: orphan) else { continue }
                storage[index].parentID = nil
            }
        }
        // Compact in bulk: amortised O(1) per eviction.
        if head >= max(64, capacity / 4) {
            storage.removeFirst(head)
            head = 0
        }
    }
}
