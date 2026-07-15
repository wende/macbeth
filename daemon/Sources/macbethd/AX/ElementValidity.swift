@preconcurrency import ApplicationServices
import Foundation

/// Marker substring embedded in the error message when a cached handle points at an
/// element the host app has since destroyed. The TypeScript client keys off this to
/// re-resolve locator-based handles from their original query path and retry once.
let staleHandleMarker = "stale-element"

/// Verify that a cached AXUIElement still refers to a live UI object.
///
/// Electron re-renders can invalidate an `AXUIElement` reference between calls — much
/// sooner than the handle table's 5-minute TTL. When that happens AX calls return
/// `kAXErrorInvalidUIElement`. We surface a clear, machine-detectable error so callers
/// can re-resolve.
///
/// Handles obtained via `query_tree` (`h_N` ids) carry no query path, so the daemon
/// cannot re-resolve them itself — the error message says so explicitly.
func ensureElementValid(_ element: AXUIElement) throws {
    var roleRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    if result == .invalidUIElement {
        throw RPCError.elementNotFound(
            "Element reference is no longer valid (\(staleHandleMarker); the app likely re-rendered). "
            + "Re-resolve it from a query, or re-run query_tree to obtain a fresh handle.")
    }
    // Any other error (e.g. .cannotComplete on a busy app) is left for the action itself
    // to encounter and report — we only special-case invalidation here.
}
