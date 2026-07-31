@preconcurrency import ApplicationServices
import Foundation

/// Thread-safe storage for AXUIElement handles.
///
/// Handles are *canonical*: storing an element that already has a live handle returns
/// that same handle instead of minting a new one, so repeated `query_tree` calls over an
/// unchanged tree hand back the same `h_N` ids and a caller can cache what it discovered.
/// See `docs/handle-lifecycle.md` for the invalidation boundaries this guarantees.
///
/// Ids are never reused: once a handle is invalidated its id stays dead, so a caller
/// holding a stale id gets a stale-handle error rather than someone else's element.
actor HandleTable {
    struct Entry {
        let element: SendableElement
        let key: ElementKey
        let pid: pid_t
        var fingerprint: ElementFingerprint
        let createdAt: Date
        var lastAccessed: Date
        var pinned: Bool
    }

    /// The three outcomes a caller must distinguish. `stale` means "this was a real
    /// handle and its element is gone" (recoverable by re-querying); `unknown` means
    /// "this daemon never issued that id" (a caller bug, or a handle from a previous
    /// daemon process).
    enum Lookup: Sendable {
        case found(SendableElement, ElementFingerprint)
        case stale(HandleInvalidation)
        case unknown
    }

    private var handles: [String: Entry] = [:]
    /// Canonical id per live element, keyed by AX reference identity (`CFEqual`).
    private var index: [ElementKey: String] = [:]
    /// Ids invalidated for a known reason, so the error can say *why*. Bounded — beyond
    /// the cap the oldest records drop and those ids degrade to the generic
    /// `.expired` classification, which is still stale-class.
    private var invalidated: [String: HandleInvalidation] = [:]
    private var invalidationOrder: [String] = []
    private var nextId: UInt64 = 0
    private let ttl: TimeInterval
    private let maxInvalidationRecords: Int

    init(ttl: TimeInterval = 300, maxInvalidationRecords: Int = 4096) {
        self.ttl = ttl
        self.maxInvalidationRecords = max(1, maxInvalidationRecords)
    }

    /// Store an element and return its handle id, reusing the existing handle when this
    /// element already has one.
    ///
    /// `fingerprint` should carry attributes the caller has already read (tree walks
    /// have them for free). When the stored fingerprint contradicts the recorded one the
    /// app has recycled the reference for a different element: the old handle is
    /// invalidated and a fresh id is minted, so nobody's cached handle silently starts
    /// pointing at the wrong control.
    @discardableResult
    func store(
        _ element: SendableElement,
        pid: pid_t,
        fingerprint: ElementFingerprint = .unknown,
        pinned: Bool = false
    ) -> String {
        let key = ElementKey(element.element)
        let now = Date()

        if let existingId = index[key], var entry = handles[existingId] {
            if entry.fingerprint.conflicts(with: fingerprint) {
                invalidate(existingId, reason: .recycled)
            } else {
                entry.lastAccessed = now
                entry.pinned = entry.pinned || pinned
                if !fingerprint.isEmpty { entry.fingerprint = fingerprint }
                handles[existingId] = entry
                return existingId
            }
        }

        let id = "h_\(nextId)"
        nextId += 1
        handles[id] = Entry(
            element: element,
            key: key,
            pid: pid,
            fingerprint: fingerprint,
            createdAt: now,
            lastAccessed: now,
            pinned: pinned
        )
        index[key] = id
        return id
    }

    /// Resolve a handle id, refreshing its last-accessed time on a hit.
    ///
    /// This is a pure table lookup — it never talks to the app. Liveness checking lives
    /// in `resolveLiveHandle`, outside the actor, so one unresponsive app cannot stall
    /// every other handle operation.
    func lookup(_ handleId: String) -> Lookup {
        if var entry = handles[handleId] {
            entry.lastAccessed = Date()
            handles[handleId] = entry
            return .found(entry.element, entry.fingerprint)
        }
        return classify(handleId)
    }

    /// Classify a handle without refreshing last-accessed times. Used on error paths.
    func classify(_ handleId: String) -> Lookup {
        if let entry = handles[handleId] {
            return .found(entry.element, entry.fingerprint)
        }
        if let reason = invalidated[handleId] {
            return .stale(reason)
        }
        // Issued at some point by this daemon process, and no longer in the table: it
        // aged out. (After a daemon restart the counter resets, so handles from the
        // previous process read as `unknown` — which is what they are.)
        if wasIssued(handleId) {
            return .stale(.expired)
        }
        return .unknown
    }

    /// Mark a handle dead. The id is not reused and the element loses its canonical slot,
    /// so the next `store` of that reference mints a fresh handle.
    func invalidate(_ handleId: String, reason: HandleInvalidation) {
        if let entry = handles.removeValue(forKey: handleId), index[entry.key] == handleId {
            index.removeValue(forKey: entry.key)
        }
        recordInvalidation(handleId, reason)
    }

    /// Pin a handle so it won't expire.
    func pin(_ handleId: String) -> Bool {
        guard var entry = handles[handleId] else { return false }
        entry.pinned = true
        entry.lastAccessed = Date()
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
    ///
    /// Expired ids are not recorded individually — `classify` infers `.expired` from the
    /// id watermark, which costs nothing and cannot grow without bound.
    func expireStale() {
        let cutoff = Date().addingTimeInterval(-ttl)
        for (id, entry) in handles where !entry.pinned && entry.lastAccessed <= cutoff {
            handles.removeValue(forKey: id)
            if index[entry.key] == id { index.removeValue(forKey: entry.key) }
        }
    }

    /// Invalidate every handle belonging to a PID, e.g. when its app quits.
    func removeHandles(forPid pid: pid_t) {
        for (id, entry) in handles where entry.pid == pid {
            invalidate(id, reason: .appTerminated)
        }
    }

    /// Number of live handles.
    var count: Int { handles.count }

    /// Number of retained invalidation records (bounded by `maxInvalidationRecords`).
    var invalidationRecordCount: Int { invalidated.count }

    // MARK: - Private

    private func wasIssued(_ handleId: String) -> Bool {
        guard handleId.hasPrefix("h_"), let n = UInt64(handleId.dropFirst(2)) else { return false }
        return n < nextId
    }

    private func recordInvalidation(_ handleId: String, _ reason: HandleInvalidation) {
        if invalidated.updateValue(reason, forKey: handleId) == nil {
            invalidationOrder.append(handleId)
        }
        guard invalidationOrder.count > maxInvalidationRecords else { return }
        // Drop the oldest quarter in one pass so trimming stays amortised O(1) even when
        // a huge app quits and invalidates tens of thousands of handles at once — but
        // never leave the record count above the cap.
        let overflow = invalidationOrder.count - maxInvalidationRecords
        let dropCount = min(invalidationOrder.count, max(overflow, maxInvalidationRecords / 4))
        for dropped in invalidationOrder.prefix(dropCount) {
            invalidated.removeValue(forKey: dropped)
        }
        invalidationOrder.removeFirst(dropCount)
    }
}
