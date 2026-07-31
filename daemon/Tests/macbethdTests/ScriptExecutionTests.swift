import Testing
import Foundation
@testable import macbethd

// MARK: - Timeout bounds

@Test func scriptTimeoutDefaultsWhenUnset() {
    #expect(ScriptTimeout.clamp(nil) == ScriptTimeout.defaultMs)
}

@Test func scriptTimeoutClampsToSafeBounds() {
    #expect(ScriptTimeout.clamp(1) == ScriptTimeout.minMs)
    #expect(ScriptTimeout.clamp(0) == ScriptTimeout.minMs)
    #expect(ScriptTimeout.clamp(-5_000) == ScriptTimeout.minMs)
    #expect(ScriptTimeout.clamp(600_000) == ScriptTimeout.maxMs)
    #expect(ScriptTimeout.clamp(Int.max) == ScriptTimeout.maxMs)
}

@Test func scriptTimeoutKeepsValuesInRange() {
    // The reported friction: 30s is too short for wide Accessibility sweeps,
    // so a caller must be able to ask for more than the default.
    #expect(ScriptTimeout.clamp(45_000) == 45_000)
    #expect(ScriptTimeout.clamp(120_000) == 120_000)
    #expect(ScriptTimeout.clamp(ScriptTimeout.maxMs) == ScriptTimeout.maxMs)
}

// MARK: - Deadline enforcement

@Test func waitReturnsWhenProcessSignalsExit() async {
    let signal = ScriptExitSignal()
    Task {
        try? await Task.sleep(for: .milliseconds(20))
        signal.signal()
    }

    let exited = await waitForScriptProcess(
        exitSignal: signal,
        until: ContinuousClock.now + .seconds(5)
    )
    #expect(exited)
}

@Test func waitReturnsImmediatelyWhenAlreadySignaled() async {
    let signal = ScriptExitSignal()
    signal.signal()

    let started = ContinuousClock.now
    let exited = await waitForScriptProcess(exitSignal: signal, until: ContinuousClock.now + .seconds(5))
    #expect(exited)
    #expect(started.duration(to: ContinuousClock.now) < .seconds(1))
}

/// Regression: a script that never exits must not hold the call open. The exit
/// waiter has to honour cancellation, otherwise the task group keeps waiting for
/// it and the deadline never takes effect.
@Test func waitGivesUpAtDeadlineWhenProcessNeverExits() async {
    let signal = ScriptExitSignal()

    let started = ContinuousClock.now
    let exited = await waitForScriptProcess(
        exitSignal: signal,
        until: ContinuousClock.now + .milliseconds(200)
    )
    let elapsed = started.duration(to: ContinuousClock.now)

    #expect(!exited)
    #expect(elapsed >= .milliseconds(150))
    #expect(elapsed < .seconds(3))
}

/// Repeated timeouts must each return on their own deadline: a stuck script
/// cannot make later work — script or otherwise — wait on it.
@Test func repeatedTimeoutsEachReturnOnTheirOwnDeadline() async {
    let stuck = ScriptExitSignal()

    for _ in 0..<3 {
        let started = ContinuousClock.now
        let exited = await waitForScriptProcess(
            exitSignal: stuck,
            until: ContinuousClock.now + .milliseconds(100)
        )
        #expect(!exited)
        #expect(started.duration(to: ContinuousClock.now) < .seconds(3))
    }

    // An unrelated script still completes normally afterwards.
    let healthy = ScriptExitSignal()
    healthy.signal()
    let recovered = await waitForScriptProcess(
        exitSignal: healthy,
        until: ContinuousClock.now + .seconds(5)
    )
    #expect(recovered)
}

@Test func concurrentWaitersAreAllReleasedBySignal() async {
    let signal = ScriptExitSignal()

    async let first = waitForScriptProcess(exitSignal: signal, until: ContinuousClock.now + .seconds(5))
    async let second = waitForScriptProcess(exitSignal: signal, until: ContinuousClock.now + .seconds(5))

    try? await Task.sleep(for: .milliseconds(20))
    signal.signal()

    let firstExited = await first
    let secondExited = await second
    #expect(firstExited)
    #expect(secondExited)
}

/// The daemon still stops a real child process at its deadline, and the
/// surrounding request returns instead of blocking on it.
@Test func realProcessIsStoppedAtItsDeadline() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]

    let signal = ScriptExitSignal()
    process.terminationHandler = { _ in signal.signal() }
    try process.run()

    let started = ContinuousClock.now
    let exited = await waitForScriptProcess(exitSignal: signal, until: ContinuousClock.now + .milliseconds(200))
    #expect(!exited)
    #expect(started.duration(to: ContinuousClock.now) < .seconds(3))

    process.terminate()
    let stopped = await waitForScriptProcess(
        exitSignal: signal,
        until: ContinuousClock.now + .milliseconds(ScriptTimeout.terminateGraceMs + 500)
    )
    #expect(stopped)
    #expect(!process.isRunning)
}
