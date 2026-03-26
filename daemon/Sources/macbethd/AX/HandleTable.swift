@preconcurrency import ApplicationServices
import Foundation

/// Thread-safe storage for AXUIElement handles with TTL-based expiration.
actor HandleTable {
    struct Entry {
        let element: SendableElement
        let pid: pid_t
        let createdAt: Date
        var lastAccessed: Date
    }

    private var handles: [String: Entry] = [:]
    private var nextId: UInt64 = 0
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }

    /// Store an element and return its opaque handle ID.
    func store(_ element: SendableElement, pid: pid_t) -> String {
        let id = "h_\(nextId)"
        nextId += 1
        let now = Date()
        handles[id] = Entry(
            element: element,
            pid: pid,
            createdAt: now,
            lastAccessed: now
        )
        return id
    }

    /// Resolve a handle ID to its AXUIElement. Updates last-accessed time.
    func resolve(_ handleId: String) -> SendableElement? {
        guard var entry = handles[handleId] else { return nil }
        entry.lastAccessed = Date()
        handles[handleId] = entry
        return entry.element
    }

    /// Remove handles not accessed within the TTL.
    func expireStale() {
        let cutoff = Date().addingTimeInterval(-ttl)
        handles = handles.filter { $0.value.lastAccessed > cutoff }
    }

    /// Remove all handles for a given PID.
    func removeHandles(forPid pid: pid_t) {
        handles = handles.filter { $0.value.pid != pid }
    }

    /// Number of active handles.
    var count: Int { handles.count }
}
