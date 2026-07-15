@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

private enum SafeMouseClickTiming {
    static let idleWaitCapMs = 5_000
    static let idlePollMs = 50
    static let activationWaitMs = 500
    static let activationPollMs = 20
    static let activationSettleMs = 50
    static let unminimizeSettleMs = 120
    static let mouseDownUpMs = 80
    static let cursorRestoreSettleMs = 20
}

struct SafeMouseClickError: Error {
    let phase: String
    let detail: String

    var message: String {
        "Mouse click failed during \(phase): \(detail)"
    }
}

/// Post a coordinate click to the element's owning window while minimizing disruption:
/// snapshot the frontmost app/window, surface only the target window, click, restore the
/// cursor, and restore the previous app/window. Restoration also runs on failure.
func performSafeMouseClick(
    element: AXUIElement,
    targetPid: pid_t,
    waitForIdleMs: Double
) async throws {
    if waitForIdleMs > 0 {
        await waitForUserIdle(requestedMs: waitForIdleMs)
        try Task.checkCancellation()
    }

    let previousPid = await MainActor.run {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    let previousFocusedWindow = previousPid.flatMap {
        ElementGeometry.focusedWindow(of: AXUIElementCreateApplication($0))
    }
    let originalCursor = CGEvent(source: nil)?.location

    guard let targetWindow = ElementGeometry.containingWindow(of: element) else {
        throw SafeMouseClickError(
            phase: "window", detail: "could not resolve the containing AXWindow")
    }

    let wasMinimized = ElementGeometry.isMinimized(targetWindow)
    if wasMinimized {
        let result = AXUIElementSetAttributeValue(
            targetWindow, kAXMinimizedAttribute as CFString, false as CFBoolean)
        guard result == .success else {
            throw SafeMouseClickError(
                phase: "unminimize", detail: "AXError \(result.rawValue)")
        }
    }

    do {
        if wasMinimized {
            try await Task.sleep(for: .milliseconds(SafeMouseClickTiming.unminimizeSettleMs))
        }
        try await activateTargetWindow(targetWindow, targetPid: targetPid)

        guard let position = ElementGeometry.position(of: element),
              let size = ElementGeometry.size(of: element) else {
            throw SafeMouseClickError(
                phase: "frame", detail: "missing AXPosition or AXSize after raising the window")
        }

        let center: CGPoint
        do {
            center = try ElementGeometry.center(position: position, size: size)
        } catch {
            throw SafeMouseClickError(
                phase: "frame", detail: "element has an unusable position or size")
        }

        try await postMouseClick(at: center)
        restoreCursor(originalCursor)
    } catch {
        restoreCursor(originalCursor)
        await restoreApplicationState(
            targetWindow: targetWindow,
            reminimize: wasMinimized,
            previousPid: previousPid,
            previousFocusedWindow: previousFocusedWindow
        )
        throw error
    }

    await restoreApplicationState(
        targetWindow: targetWindow,
        reminimize: wasMinimized,
        previousPid: previousPid,
        previousFocusedWindow: previousFocusedWindow
    )
}

private func activateTargetWindow(_ window: AXUIElement, targetPid: pid_t) async throws {
    await MainActor.run {
        _ = NSRunningApplication(processIdentifier: targetPid)?.activate(options: [])
    }

    let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    guard raiseResult == .success else {
        throw SafeMouseClickError(phase: "raise", detail: "AXError \(raiseResult.rawValue)")
    }

    let deadline = ContinuousClock.now.advanced(
        by: .milliseconds(SafeMouseClickTiming.activationWaitMs))
    while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        let isActive = await MainActor.run {
            NSRunningApplication(processIdentifier: targetPid)?.isActive == true
        }
        if isActive { break }
        try await Task.sleep(for: .milliseconds(SafeMouseClickTiming.activationPollMs))
    }

    let isActive = await MainActor.run {
        NSRunningApplication(processIdentifier: targetPid)?.isActive == true
    }
    guard isActive else {
        throw SafeMouseClickError(
            phase: "activate", detail: "target app did not become active within 500ms")
    }
    try await Task.sleep(for: .milliseconds(SafeMouseClickTiming.activationSettleMs))
}

private func restoreApplicationState(
    targetWindow: AXUIElement,
    reminimize: Bool,
    previousPid: pid_t?,
    previousFocusedWindow: AXUIElement?
) async {
    if reminimize {
        let result = AXUIElementSetAttributeValue(
            targetWindow, kAXMinimizedAttribute as CFString, true as CFBoolean)
        if result != .success {
            vlog("Mouse click could not re-minimize target window (AXError \(result.rawValue))")
        }
    }

    guard let previousPid else { return }
    await MainActor.run {
        _ = NSRunningApplication(processIdentifier: previousPid)?.activate(options: [])
    }
    if let previousFocusedWindow {
        let result = AXUIElementPerformAction(
            previousFocusedWindow, kAXRaiseAction as CFString)
        if result != .success {
            vlog("Mouse click could not restore previous focused window (AXError \(result.rawValue))")
        }
    }
}

private func waitForUserIdle(requestedMs: Double) async {
    let idleThreshold = min(max(requestedMs, 0), Double(SafeMouseClickTiming.idleWaitCapMs)) / 1_000
    let deadline = ContinuousClock.now.advanced(
        by: .milliseconds(SafeMouseClickTiming.idleWaitCapMs))

    while ContinuousClock.now < deadline {
        if Task.isCancelled { return }
        let sinceKey = CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: .keyDown)
        let sinceMouseDown = CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: .leftMouseDown)
        let sinceMouseMove = CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: .mouseMoved)
        if min(sinceKey, min(sinceMouseDown, sinceMouseMove)) >= idleThreshold {
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(SafeMouseClickTiming.idlePollMs))
        } catch {
            return
        }
    }
}

private func postMouseClick(at point: CGPoint) async throws {
    let source = CGEventSource(stateID: .hidSystemState)
    guard let moved = CGEvent(
        mouseEventSource: source, mouseType: .mouseMoved,
        mouseCursorPosition: point, mouseButton: .left),
        let down = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left),
        let up = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left)
    else {
        throw SafeMouseClickError(
            phase: "events", detail: "could not create a complete mouse event sequence")
    }

    moved.post(tap: .cghidEventTap)
    down.post(tap: .cghidEventTap)
    do {
        try await Task.sleep(for: .milliseconds(SafeMouseClickTiming.mouseDownUpMs))
    } catch {
        up.post(tap: .cghidEventTap)
        throw error
    }
    up.post(tap: .cghidEventTap)
}

private func restoreCursor(_ originalCursor: CGPoint?) {
    guard let originalCursor else { return }
    usleep(useconds_t(SafeMouseClickTiming.cursorRestoreSettleMs * 1_000))
    let result = CGWarpMouseCursorPosition(originalCursor)
    if result != .success {
        vlog("Cursor restoration failed (error: \(result.rawValue))")
    }
}
