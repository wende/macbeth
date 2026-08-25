@preconcurrency import ApplicationServices
import Foundation

/// Typed error for a handle this daemon issued whose element is gone. Recoverable: the
/// caller re-resolves from the query path that produced it.
func staleHandleError(_ handleId: String?, reason: HandleInvalidation) -> RPCError {
    let subject = handleId.map { "Handle \($0)" } ?? "Element reference"
    return RPCError.staleHandle(
        "\(subject) is no longer usable (\(staleHandleMarker), reason: \(reason.rawValue)). "
        + reason.recovery,
        handleId: handleId,
        reason: reason.rawValue
    )
}

/// Typed error for a handle id this daemon never issued. Not recoverable by retrying the
/// same id — it is a caller bug, or a handle left over from a previous daemon process.
func unknownHandleError(_ handleId: String) -> RPCError {
    RPCError.unknownHandle(
        "Unknown handle \(handleId): this daemon never issued it (handles do not survive a "
        + "daemon restart). Run query_tree or get_element to obtain a valid handle.",
        handleId: handleId,
        reason: "never_issued"
    )
}

/// Resolve a handle id to a live element, or throw a typed error saying precisely why not.
///
/// Three outcomes are distinguished, because they call for different recovery:
///  - unknown handle → `unknown_handle` (-32011); re-querying the same id will never help
///  - stale handle → `stale_handle` (-32010) with `data.reason`; re-resolve from the query
///  - live → the element, after confirming with the app that it still exists
///
/// The liveness check runs outside the `HandleTable` actor so a slow app blocks only this
/// call, and it doubles as the recycled-reference check: if the app handed the same AX
/// reference to a different element, the recorded fingerprint contradicts the current one
/// and the handle is retired instead of quietly acting on the wrong control.
func resolveLiveHandle(
    _ handleId: String,
    in handleTable: HandleTable,
    expectedPid: pid_t? = nil
) async throws -> SendableElement {
    switch await handleTable.lookup(handleId) {
    case .unknown:
        throw unknownHandleError(handleId)

    case .stale(let reason):
        throw staleHandleError(handleId, reason: reason)

    case .found(let element, let recorded, let pid):
        try ensureHandleBelongsToApp(handleId, actualPid: pid, expectedPid: expectedPid)
        let (alive, current) = ElementFingerprint.captureChecked(element.element)
        if !alive {
            await handleTable.invalidate(handleId, reason: .destroyed)
            throw staleHandleError(handleId, reason: .destroyed)
        }
        if recorded.conflicts(with: current) {
            await handleTable.invalidate(handleId, reason: .recycled)
            throw staleHandleError(handleId, reason: .recycled)
        }
        return element
    }
}

/// App-scoped methods must not accept a live handle minted for another process.
/// Keeping this check in the shared resolver covers actions and read operations alike.
func ensureHandleBelongsToApp(
    _ handleId: String,
    actualPid: pid_t,
    expectedPid: pid_t?
) throws {
    guard let expectedPid, actualPid != expectedPid else { return }
    // Treat this as unknown in the supplied app's namespace. Besides being
    // precise for direct callers, it lets scoped locators recover after a
    // daemon restart reuses the same numeric handle for another process.
    throw RPCError.unknownHandle(
        "Handle \(handleId) was not issued for the supplied appHandle; re-query the app",
        handleId: handleId,
        reason: "wrong_app"
    )
}

/// Build the error for a handle-table operation that needs no liveness check (pinning,
/// for instance) but still has to explain a miss.
func handleLookupError(_ handleId: String, _ outcome: HandleTable.Lookup) -> RPCError {
    switch outcome {
    case .unknown:
        unknownHandleError(handleId)
    case .stale(let reason):
        staleHandleError(handleId, reason: reason)
    case .found:
        // Unreachable by construction: a lookup only misses when the id is absent from
        // `handles`, and nothing puts an id back — `store` always mints a fresh id from a
        // monotonic counter. The branch exists because the switch must be exhaustive, and
        // it reports a recoverable code rather than a generic one so that if some future
        // code path *does* revive ids, callers retry instead of hard-failing.
        // `isRecoverableHandleError` keys off `data.reason`, which elementNotFound lacks.
        RPCError.staleHandle(
            "Handle \(handleId) could not be updated (\(staleHandleMarker), reason: transient). "
            + "A concurrent operation raced this one; re-resolve from the query path and retry.",
            handleId: handleId,
            reason: "transient"
        )
    }
}

/// Per-id error code string for a failed entry in a bulk `pin_handle` result. Mirrors
/// the code path a single failed pin would throw, without the full message — bulk
/// callers just need to know "this id couldn't be pinned" and the typed reason.
func bulkPinErrorCode(id: String, classify: HandleTable.Lookup) -> String {
    switch classify {
    case .unknown: return "unknown_handle"
    case .stale(let reason): return "stale_handle: \(reason.rawValue)"
    case .found:
        // Unreachable: the caller only reaches this after `pin(id)` returned false, which
        // means the id is absent from `handles` — exactly when `classify` cannot return
        // `.found`. Kept for switch exhaustiveness; mirrors `handleLookupError`'s code.
        return "stale_handle: transient"
    }
}
