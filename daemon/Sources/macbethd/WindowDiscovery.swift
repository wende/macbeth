import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit can return tiny offscreen bookkeeping windows when
/// `onScreenWindowsOnly` is false (Steam, for example, exposes 1×1 windows at
/// large negative coordinates). They cannot produce useful captures or input.
func isUsableCaptureFrame(_ frame: CGRect) -> Bool {
    let hasFiniteGeometry = frame.origin.x.isFinite
        && frame.origin.y.isFinite
        && frame.width.isFinite
        && frame.height.isFinite
    return hasFiniteGeometry && frame.width > 1 && frame.height > 1
}

func isDisplayEdgeStrip(_ frame: CGRect, displayFrames: [CGRect]) -> Bool {
    guard frame.height <= 64 else { return false }
    return displayFrames.contains { display in
        abs(frame.minX - display.minX) <= 1
            && abs(frame.maxX - display.maxX) <= 1
            && abs(frame.minY - display.minY) <= 1
    }
}

func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
    guard read == size, info.pbi_ppid > 0 else { return nil }
    return pid_t(info.pbi_ppid)
}

func isDescendantProcess(
    _ pid: pid_t,
    of rootPID: pid_t,
    parentOf: (pid_t) -> pid_t? = parentPID
) -> Bool {
    var current = pid
    var visited: Set<pid_t> = []
    for _ in 0..<32 {
        if current == rootPID { return true }
        guard visited.insert(current).inserted,
              let parent = parentOf(current),
              parent > 0 else { return false }
        current = parent
    }
    return false
}

func windowOwnerPIDs(in content: SCShareableContent, rootedAt pid: pid_t) -> Set<pid_t> {
    Set(content.applications.compactMap { application in
        let candidate = application.processID
        return isDescendantProcess(candidate, of: pid) ? candidate : nil
    }).union([pid])
}

func isCapturableWindow(_ window: SCWindow, displayFrames: [CGRect]) -> Bool {
    window.windowLayer == 0
        && isUsableCaptureFrame(window.frame)
        && !isDisplayEdgeStrip(window.frame, displayFrames: displayFrames)
}

func capturableWindows(in content: SCShareableContent, ownedBy pid: pid_t) -> [SCWindow] {
    let displayFrames = content.displays.map(\.frame)
    let ownerPIDs = windowOwnerPIDs(in: content, rootedAt: pid)
    return content.windows.filter {
        $0.owningApplication.map { ownerPIDs.contains($0.processID) } == true
            && isCapturableWindow($0, displayFrames: displayFrames)
    }
}

/// Resolve an explicitly selected WindowServer window. Explicit selection
/// includes descendant/helper processes because apps such as Steam host real
/// windows in child processes.
func resolveSelectedWindow(
    in content: SCShareableContent,
    ownedBy pid: pid_t,
    windowID: Int
) throws -> SCWindow {
    guard let window = capturableWindows(in: content, ownedBy: pid)
        .first(where: { Int($0.windowID) == windowID }) else {
        throw RPCError.elementNotFound(
            "No capturable window \(windowID) for app (PID: \(pid))")
    }
    return window
}

/// Preserve the pre-existing screenshot/OCR behavior when no window ID is
/// supplied: use the first on-screen window owned by the connected root PID.
func resolveDefaultWindow(
    in content: SCShareableContent,
    ownedBy pid: pid_t
) throws -> SCWindow {
    guard let window = content.windows.first(where: {
        $0.owningApplication?.processID == pid
    }) else {
        throw RPCError.elementNotFound(
            "No visible windows for app (PID: \(pid))")
    }
    return window
}

func windowKind(_ window: SCWindow, displayFrames: [CGRect]) -> String {
    if !isUsableCaptureFrame(window.frame) { return "bookkeeping" }
    if isDisplayEdgeStrip(window.frame, displayFrames: displayFrames) { return "menu_bar" }
    if window.windowLayer != 0 { return "overlay" }
    return "window"
}

func windowJSON(
    _ window: SCWindow,
    displayFrames: [CGRect],
    isDefault: Bool
) -> JSONValue {
    let frame = window.frame
    return .object([
        "windowId": .number(Double(window.windowID)),
        "ownerPid": .number(Double(window.owningApplication?.processID ?? 0)),
        "ownerName": window.owningApplication.map { .string($0.applicationName) } ?? .null,
        "bundleId": window.owningApplication.map { .string($0.bundleIdentifier) } ?? .null,
        "title": window.title.flatMap { $0.isEmpty ? nil : $0 }.map(JSONValue.string) ?? .null,
        "frame": .object([
            "x": .number(frame.origin.x),
            "y": .number(frame.origin.y),
            "width": .number(frame.width),
            "height": .number(frame.height),
        ]),
        "layer": .number(Double(window.windowLayer)),
        "onScreen": .bool(window.isOnScreen),
        "active": .bool(window.isActive),
        "capturable": .bool(isCapturableWindow(window, displayFrames: displayFrames)),
        "kind": .string(windowKind(window, displayFrames: displayFrames)),
        "default": .bool(isDefault),
    ])
}
