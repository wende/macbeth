@preconcurrency import ApplicationServices
import Foundation

/// Thread-safe storage for AXUIElement handles with TTL-based expiration.
actor HandleTable {
    struct Entry {
        let element: SendableElement
        let pid: pid_t
        let createdAt: Date
        var lastAccessed: Date
        var pinned: Bool
    }

    private var handles: [String: Entry] = [:]
    private var nextId: UInt64 = 0
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }

    /// Store an element and return its opaque handle ID.
    func store(_ element: SendableElement, pid: pid_t, pinned: Bool = false) -> String {
        let id = "h_\(nextId)"
        nextId += 1
        let now = Date()
        handles[id] = Entry(
            element: element,
            pid: pid,
            createdAt: now,
            lastAccessed: now,
            pinned: pinned
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

    /// Pin a handle so it won't expire.
    func pin(_ handleId: String) -> Bool {
        guard var entry = handles[handleId] else { return false }
        entry.pinned = true
        handles[handleId] = entry
        return true
    }

    /// Unpin a handle, resuming normal TTL expiry.
    func unpin(_ handleId: String) -> Bool {
        guard var entry = handles[handleId] else { return false }
        entry.pinned = false
        entry.lastAccessed = Date()
        handles[handleId] = entry
        return true
    }

    /// Remove handles not accessed within the TTL (skips pinned handles).
    func expireStale() {
        let cutoff = Date().addingTimeInterval(-ttl)
        handles = handles.filter { $0.value.pinned || $0.value.lastAccessed > cutoff }
    }

    /// Remove all handles for a given PID.
    func removeHandles(forPid pid: pid_t) {
        handles = handles.filter { $0.value.pid != pid }
    }

    /// Number of active handles.
    var count: Int { handles.count }
}
