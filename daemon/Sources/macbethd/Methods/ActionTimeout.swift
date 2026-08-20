import Foundation

/// Bounds for UI actions that may wait for an element before operating on it.
/// The client mirrors these limits, but the daemon clamps independently for
/// callers that use the JSON-RPC socket directly.
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
