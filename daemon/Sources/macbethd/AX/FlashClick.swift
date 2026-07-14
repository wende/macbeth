@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

/// Named timing constants for the flash click. Every unavoidable delay lives
/// here with a rationale so regressions in flash duration are auditable.
enum FlashClickTiming {
    /// Cap on waiting for `didActivateApplicationNotification` before falling
    /// through with a warning. The activation usually lands in <100ms.
    static let activationWaitCapMs = 500
    /// After activation the window server needs a beat for window ordering to
    /// take effect before a posted click lands on the right window.
    static let settleAfterActivationMs = 40
    /// Gap between mouse-down and mouse-up so the target treats it as a real
    /// click, not a flick.
    static let downUpGapMs = 20
    /// After un-minimizing, let the deminiaturize finish so the frame we read
    /// is the live on-screen frame, not a stale/zero one.
    static let unminimizeSettleMs = 250
    /// Hard cap on the optional user-idle wait — never block a click forever.
    static let idleWaitCapMs = 5000
    /// Poll interval while waiting for the user to go idle.
    static let idlePollMs = 20
}

/// A structured failure inside the flash sequence, tagged with the phase that
/// failed (surfaced to callers as `flash_click_failed: <phase>`).
struct FlashClickError: Error {
    let phase: String
    let detail: String
    var message: String { "flash_click_failed: \(phase) — \(detail)" }
}

/// Simple phase timer used for verbose instrumentation.
private struct PhaseTimer {
    private let clock = ContinuousClock()
    private var last: ContinuousClock.Instant
    private let verbose: Bool
    private var lines: [String] = []
    private let start: ContinuousClock.Instant

    init(verbose: Bool) {
        self.verbose = verbose
        let now = ContinuousClock().now
        self.last = now
        self.start = now
    }

    mutating func mark(_ phase: String) {
        guard verbose else { return }
        let now = clock.now
        let ms = (last.duration(to: now)).milliseconds
        lines.append("  \(phase): \(ms)ms")
        last = now
    }

    func flush() {
        guard verbose else { return }
        let total = start.duration(to: clock.now).milliseconds
        fputs("[macbethd] flash click phases (total \(total)ms):\n" + lines.joined(separator: "\n") + "\n", stderr)
    }
}

private extension Duration {
    var milliseconds: Int {
        let (secs, atto) = components
        return Int(secs * 1000) + Int(atto / 1_000_000_000_000_000)
    }
}

/// Perform a "flash click": briefly activate the target app, raise only the
/// target window, post a real global click at the element's center, then restore
/// the previously frontmost app and window. Robust universal fallback for
/// elements AXPress cannot drive.
///
/// - Parameters:
///   - element: the target element to click.
///   - targetPid: pid of the app owning the element.
///   - waitForIdleMs: if > 0, wait until the user has been idle this long
///     (capped) before stealing focus, to avoid leaking keystrokes.
///   - verbose: emit per-phase timing to stderr.
func performFlashClick(
    element: AXUIElement,
    targetPid: pid_t,
    waitForIdleMs: Double,
    verbose: Bool
) async throws {
    var timer = PhaseTimer(verbose: verbose)

    // Phase 0: optionally wait for the user to stop typing/moving the mouse so
    // the focus steal doesn't swallow their input.
    if waitForIdleMs > 0 {
        await waitForUserIdle(idleMs: waitForIdleMs)
        timer.mark("idle_wait")
    }

    // Phase 1: snapshot the state we must restore afterwards.
    let previousPid: pid_t? = await MainActor.run {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    // Focused window of the previous app (so multi-window apps restore correctly).
    // Captured off the main actor — AX calls are thread-safe.
    let previousFocusedWindow: AXUIElement? = previousPid.flatMap { pid in
        focusedWindow(of: AXUIElementCreateApplication(pid))
    }
    timer.mark("snapshot")

    // Phase 2 (pre-checks): resolve the containing window and un-minimize it.
    guard let window = containingWindow(of: element) else {
        throw FlashClickError(phase: "window", detail: "could not resolve containing AXWindow")
    }

    var didUnminimize = false
    if isWindowMinimized(window) {
        let r = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFBoolean)
        if r != .success {
            throw FlashClickError(phase: "unminimize", detail: "AXError \(r.rawValue)")
        }
        didUnminimize = true
        // Deminiaturize is animated; give it a beat before reading the frame.
        try? await Task.sleep(for: .milliseconds(FlashClickTiming.unminimizeSettleMs))
    }
    timer.mark("prechecks")

    // Everything from activation onward must restore state even on failure.
    do {
        // Phase 3: activate the app (one window, NOT the whole stack) and raise
        // the specific target window.
        await MainActor.run {
            // Explicitly [] — not .activateAllWindows — so we surface one window.
            _ = NSRunningApplication(processIdentifier: targetPid)?.activate(options: [])
        }

        let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if raiseResult != .success {
            throw FlashClickError(phase: "raise", detail: "AXError \(raiseResult.rawValue)")
        }

        // Wait for readiness via the activation notification rather than a fixed
        // sleep; fall through with a warning if it never arrives.
        let waiter = await ActivationWaiter()
        let activated = await waiter.wait(
            pid: targetPid, timeoutMs: FlashClickTiming.activationWaitCapMs
        )
        if !activated && verbose {
            fputs("[macbethd] flash click: activation notification for pid \(targetPid) not received within \(FlashClickTiming.activationWaitCapMs)ms; proceeding\n", stderr)
        }
        // One short settle for window-server ordering to take effect.
        try? await Task.sleep(for: .milliseconds(FlashClickTiming.settleAfterActivationMs))
        timer.mark("activate_raise")

        // Read the frame AFTER the window is raised — layout can shift.
        guard let position = elementPosition(element), let size = elementSize(element) else {
            throw FlashClickError(phase: "frame", detail: "missing AXPosition/AXSize after raise")
        }
        let center: CGPoint
        do {
            center = try clickCenter(position: position, size: size)
        } catch let e as FrameGeometryError {
            throw FlashClickError(phase: "frame", detail: e.message)
        }
        timer.mark("frame")

        // Phase 4: post the global click.
        await postFlashClick(at: center)
        timer.mark("click")
    } catch {
        await restoreState(
            didUnminimize: didUnminimize, window: window,
            previousPid: previousPid, previousFocusedWindow: previousFocusedWindow
        )
        timer.mark("restore")
        timer.flush()
        throw error
    }

    // Phase 5: restore.
    await restoreState(
        didUnminimize: didUnminimize, window: window,
        previousPid: previousPid, previousFocusedWindow: previousFocusedWindow
    )
    timer.mark("restore")
    timer.flush()
}

// MARK: - Restore

private func restoreState(
    didUnminimize: Bool,
    window: AXUIElement,
    previousPid: pid_t?,
    previousFocusedWindow: AXUIElement?
) async {
    // Re-minimize if we un-minimized it for the click.
    if didUnminimize {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFBoolean)
    }

    // No previous frontmost app (rare, e.g. daemon-triggered at login): skip.
    guard let previousPid else { return }

    await MainActor.run {
        _ = NSRunningApplication(processIdentifier: previousPid)?.activate(options: [])
    }
    // Raise the previously focused window if it's still valid — it may have
    // closed; ignore any error.
    if let previousFocusedWindow {
        AXUIElementPerformAction(previousFocusedWindow, kAXRaiseAction as CFString)
    }
}

// MARK: - Activation notification wait

/// Awaits `NSWorkspace.didActivateApplicationNotification` for a specific pid,
/// capped by a timeout. Main-actor isolated so the observer, timeout, and
/// continuation share state without data races (all resume paths funnel through
/// `finish`, which runs exactly once).
@MainActor
private final class ActivationWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var token: NSObjectProtocol?
    private var finished = false

    /// Returns true if the activation notification arrived, false on timeout.
    func wait(pid: pid_t, timeoutMs: Int) async -> Bool {
        // Already frontmost — nothing to wait for.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            return true
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont
            let center = NSWorkspace.shared.notificationCenter

            self.token = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.processIdentifier == pid else { return }
                // The .main queue guarantees we're on the main thread/actor.
                MainActor.assumeIsolated { self?.finish(true) }
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                self?.finish(false)
            }
        }
    }

    private func finish(_ value: Bool) {
        guard !finished else { return }
        finished = true
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            self.token = nil
        }
        continuation?.resume(returning: value)
        continuation = nil
    }
}

// MARK: - User idle wait

/// Poll HID event timestamps until the user has been idle for `idleMs`, capped
/// at `FlashClickTiming.idleWaitCapMs`, then proceed regardless.
private func waitForUserIdle(idleMs: Double) async {
    let idleThreshold = idleMs / 1000.0
    let deadline = Date().addingTimeInterval(Double(FlashClickTiming.idleWaitCapMs) / 1000.0)

    while Date() < deadline {
        let sinceKey = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let sinceMouseDown = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown)
        let sinceMouseMoved = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let idle = min(sinceKey, min(sinceMouseDown, sinceMouseMoved))
        if idle >= idleThreshold { return }
        try? await Task.sleep(for: .milliseconds(FlashClickTiming.idlePollMs))
    }
}

// MARK: - Click posting

/// Post mouse-moved → mouse-down → (gap) → mouse-up as global HID events using a
/// dedicated HID-state event source.
private func postFlashClick(at point: CGPoint) async {
    let source = CGEventSource(stateID: .hidSystemState)
    let moved = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                        mouseCursorPosition: point, mouseButton: .left)
    let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                       mouseCursorPosition: point, mouseButton: .left)
    let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                     mouseCursorPosition: point, mouseButton: .left)

    moved?.post(tap: .cghidEventTap)
    down?.post(tap: .cghidEventTap)
    try? await Task.sleep(for: .milliseconds(FlashClickTiming.downUpGapMs))
    up?.post(tap: .cghidEventTap)
}
