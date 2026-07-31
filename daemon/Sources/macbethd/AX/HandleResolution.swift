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
        handleId: handleId
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
func resolveLiveHandle(_ handleId: String, in handleTable: HandleTable) async throws -> SendableElement {
    switch await handleTable.lookup(handleId) {
    case .unknown:
        throw unknownHandleError(handleId)

    case .stale(let reason):
        throw staleHandleError(handleId, reason: reason)

    case .found(let element, let recorded):
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

/// Build the error for a handle-table operation that needs no liveness check (pinning,
/// for instance) but still has to explain a miss.
func handleLookupError(_ handleId: String, _ outcome: HandleTable.Lookup) -> RPCError {
    switch outcome {
    case .unknown:
        unknownHandleError(handleId)
    case .stale(let reason):
        staleHandleError(handleId, reason: reason)
    case .found:
        // The handle came back live on the second look — a concurrent call revived it.
        // Report it as a transient miss rather than inventing a lifecycle reason.
        RPCError.elementNotFound("Handle \(handleId) could not be updated; retry the call.")
    }
}
