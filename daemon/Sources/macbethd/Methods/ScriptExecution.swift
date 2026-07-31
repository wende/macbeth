@preconcurrency import Foundation

/// Bounds and grace periods for caller-configurable script deadlines.
///
/// A script timeout is an *operation* failure: it stops that one script and is
/// reported as a typed timeout to that one caller. It is never a daemon fault,
/// so unrelated RPCs (`connect_app`, `query_tree`, …) keep working while a slow
/// script runs and after it is stopped.
///
/// These bounds mirror `SCRIPT_TIMEOUT` in `client/src/timeouts.ts`. The daemon
/// clamps independently so a hand-written RPC call cannot request an unbounded run.
enum ScriptTimeout {
    static let defaultMs = 30_000
    static let minMs = 100
    static let maxMs = 300_000

    /// How long a script process gets to exit after SIGTERM before SIGKILL.
    static let terminateGraceMs = 200
    /// How long to wait for a killed process to be reaped before giving up on
    /// its exit status. Bounded so a wedged child cannot pin the request.
    static let reapGraceMs = 1_000

    static func clamp(_ requestedMs: Int?) -> Int {
        guard let requestedMs else { return defaultMs }
        return min(max(requestedMs, minMs), maxMs)
    }
}

/// One-shot completion signal for process exit, safe to fire before or after
/// waiters attach.
///
/// Waiting honours task cancellation. That matters: the deadline race below
/// cancels the exit waiter when the timeout wins, and a task group only returns
/// once every child has finished. An uncancellable waiter would keep the whole
/// `run_applescript` call parked until the script exited on its own — which is
/// exactly the case the deadline exists to handle.
final class ScriptExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var signaled = false

    var hasSignaled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }

    func signal() {
        lock.lock()
        signaled = true
        let parked = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        // Resume outside the lock so a continuation cannot re-enter it.
        for continuation in parked { continuation.resume() }
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if signaled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume()
        }
    }
}

/// Wait until the script process exits or `deadline` elapses — no polling.
///
/// Returns `true` when the process signalled exit, `false` when the deadline
/// (or cancellation of the calling task) won.
@discardableResult
func waitForScriptProcess(
    exitSignal: ScriptExitSignal,
    until deadline: ContinuousClock.Instant
) async -> Bool {
    if exitSignal.hasSignaled { return true }

    await withTaskGroup(of: Void.self) { group in
        group.addTask { await exitSignal.wait() }
        group.addTask { try? await Task.sleep(until: deadline, clock: .continuous) }
        // First finisher wins: process exit or deadline. Cancelling releases the
        // loser so this call returns as soon as either happens.
        await group.next()
        group.cancelAll()
    }

    return exitSignal.hasSignaled
}
