import Foundation

/// Bounds for UI actions that may wait for an element before operating on it.
/// Min and max match the TypeScript `ACTION_TIMEOUT` constants. The 5s default
/// is the historical wire default for callers that omit `timeout`; the
/// TypeScript client and MCP tools send 30s instead. The daemon still clamps
/// independently so a hand-written RPC call cannot ask for an unbounded wait.
enum ActionTimeout {
    static let defaultSeconds = 5.0
    static let minSeconds = 0.1
    static let maxSeconds = 300.0

    static func clamp(_ requestedSeconds: Double?) -> Double {
        guard let requestedSeconds, requestedSeconds.isFinite else {
            return defaultSeconds
        }
        return min(max(requestedSeconds, minSeconds), maxSeconds)
    }
}
