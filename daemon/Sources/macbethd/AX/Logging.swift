import Foundation

/// Global verbose flag. Set once at startup (before the server accepts requests),
/// then only read — so `nonisolated(unsafe)` is safe here under Swift 6 strict concurrency.
nonisolated(unsafe) var verboseLogging = false

/// Emit a diagnostic line to stderr when running in verbose mode.
func vlog(_ message: @autoclosure () -> String) {
    if verboseLogging {
        fputs("[macbethd] \(message())\n", stderr)
    }
}
