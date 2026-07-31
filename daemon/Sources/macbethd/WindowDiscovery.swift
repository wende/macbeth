@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

/// Provider-independent view of a WindowServer surface. `SCWindow` cannot be
/// constructed outside ScreenCaptureKit, so every filtering and serialisation
/// rule below works on this struct and stays testable.
struct WindowDescriptor: Sendable, Equatable {
    var windowID: UInt32
    var ownerPID: pid_t?
    var ownerName: String?
    var bundleID: String?
    var title: String?
    var frame: CGRect
    var layer: Int
    var isOnScreen: Bool
    var isActive: Bool

    init(
        windowID: UInt32,
        ownerPID: pid_t? = nil,
        ownerName: String? = nil,
        bundleID: String? = nil,
        title: String? = nil,
        frame: CGRect,
        layer: Int = 0,
        isOnScreen: Bool = true,
        isActive: Bool = false
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.isActive = isActive
    }

    init(_ window: SCWindow) {
        self.init(
            windowID: window.windowID,
            ownerPID: window.owningApplication?.processID,
            ownerName: window.owningApplication?.applicationName,
            bundleID: window.owningApplication?.bundleIdentifier,
            title: window.title.flatMap { $0.isEmpty ? nil : $0 },
            frame: window.frame,
            layer: window.windowLayer,
            isOnScreen: window.isOnScreen,
            isActive: window.isActive
        )
    }
}

/// Window facts only the accessibility API knows: the role/subrole the app
/// declares, and whether the window is minimised into the Dock (WindowServer
/// keeps reporting a frame for minimised windows, so `onScreen` alone cannot
/// answer "is this window on the desk?").
struct AXWindowMetadata: Sendable, Equatable {
    var role: String?
    var subrole: String?
    var minimized: Bool

    init(role: String? = nil, subrole: String? = nil, minimized: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.minimized = minimized
    }
}

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

func isCapturableWindow(_ window: WindowDescriptor, displayFrames: [CGRect]) -> Bool {
    window.layer == 0
        && isUsableCaptureFrame(window.frame)
        && !isDisplayEdgeStrip(window.frame, displayFrames: displayFrames)
}

func isCapturableWindow(_ window: SCWindow, displayFrames: [CGRect]) -> Bool {
    isCapturableWindow(WindowDescriptor(window), displayFrames: displayFrames)
}

func capturableWindows(in content: SCShareableContent, ownedBy pid: pid_t) -> [SCWindow] {
    let displayFrames = content.displays.map(\.frame)
    let ownerPIDs = windowOwnerPIDs(in: content, rootedAt: pid)
    return content.windows.filter {
        $0.owningApplication.map { ownerPIDs.contains($0.processID) } == true
            && isCapturableWindow($0, displayFrames: displayFrames)
    }
}

/// Every window owned by an app or one of its helper processes, in the order
/// ScreenCaptureKit reports them.
func ownedWindows(in content: SCShareableContent, rootedAt pid: pid_t) -> [WindowDescriptor] {
    let ownerPIDs = windowOwnerPIDs(in: content, rootedAt: pid)
    return content.windows
        .filter { $0.owningApplication.map { ownerPIDs.contains($0.processID) } == true }
        .map { WindowDescriptor($0) }
}

/// Choose the default capture target among root-PID candidates.
/// Prefers on-screen capturable windows and never selects bookkeeping,
/// menu-bar, or overlay surfaces. Shared by `list_windows` (`default` flag)
/// and screenshot/OCR when no `windowId` is supplied.
func selectDefaultWindowID(
    from candidates: [(windowID: UInt32, isOnScreen: Bool, capturable: Bool)]
) -> UInt32? {
    let capturable = candidates.filter(\.capturable)
    return capturable.first(where: \.isOnScreen)?.windowID
        ?? capturable.first?.windowID
}

/// Per-owner default targets, for an unfiltered listing where there is no
/// single connected app. Each owning process gets the window that screenshot
/// and OCR would capture for it.
func defaultWindowIDsByOwner(
    among descriptors: [WindowDescriptor],
    displayFrames: [CGRect]
) -> Set<UInt32> {
    var byOwner: [pid_t: [WindowDescriptor]] = [:]
    for descriptor in descriptors {
        guard let pid = descriptor.ownerPID else { continue }
        byOwner[pid, default: []].append(descriptor)
    }
    var defaults: Set<UInt32> = []
    for group in byOwner.values {
        var candidates: [(windowID: UInt32, isOnScreen: Bool, capturable: Bool)] = []
        for descriptor in group {
            candidates.append((
                windowID: descriptor.windowID,
                isOnScreen: descriptor.isOnScreen,
                capturable: isCapturableWindow(descriptor, displayFrames: displayFrames)
            ))
        }
        if let defaultID = selectDefaultWindowID(from: candidates) {
            defaults.insert(defaultID)
        }
    }
    return defaults
}

func findDefaultRootWindow(
    in content: SCShareableContent,
    ownedBy pid: pid_t
) -> SCWindow? {
    let displayFrames = content.displays.map(\.frame)
    let candidates = content.windows.compactMap { window -> (SCWindow, UInt32, Bool, Bool)? in
        guard window.owningApplication?.processID == pid else { return nil }
        return (
            window,
            window.windowID,
            window.isOnScreen,
            isCapturableWindow(window, displayFrames: displayFrames)
        )
    }
    guard let defaultID = selectDefaultWindowID(
        from: candidates.map { ($0.1, $0.2, $0.3) }
    ) else {
        return nil
    }
    return candidates.first(where: { $0.1 == defaultID })?.0
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
/// supplied: use the first capturable on-screen window owned by the connected
/// root PID (same rule as the `default` flag from `list_windows`).
func resolveDefaultWindow(
    in content: SCShareableContent,
    ownedBy pid: pid_t
) throws -> SCWindow {
    guard let window = findDefaultRootWindow(in: content, ownedBy: pid) else {
        throw RPCError.elementNotFound(
            "No visible windows for app (PID: \(pid))")
    }
    return window
}

func windowKind(_ window: WindowDescriptor, displayFrames: [CGRect]) -> String {
    if !isUsableCaptureFrame(window.frame) { return "bookkeeping" }
    if isDisplayEdgeStrip(window.frame, displayFrames: displayFrames) { return "menu_bar" }
    if window.layer != 0 { return "overlay" }
    return "window"
}

/// Drop the surfaces an agent almost never means by "window" — menu-bar strips,
/// overlays, and bookkeeping sentinels — unless the caller asked for everything.
func listedWindows(
    _ descriptors: [WindowDescriptor],
    displayFrames: [CGRect],
    includeAllSurfaces: Bool
) -> [WindowDescriptor] {
    guard !includeAllSurfaces else { return descriptors }
    return descriptors.filter { windowKind($0, displayFrames: displayFrames) == "window" }
}

private func jsonString(_ value: String?) -> JSONValue {
    guard let value else { return .null }
    return .string(value)
}

/// Built field by field rather than as one dictionary literal: a literal this
/// wide (nested object, several optionals) exceeds the type checker's budget.
func windowJSON(
    _ window: WindowDescriptor,
    displayFrames: [CGRect],
    isDefault: Bool,
    accessibility: AXWindowMetadata?
) -> JSONValue {
    let frame = window.frame
    var frameFields: [String: JSONValue] = [:]
    frameFields["x"] = .number(Double(frame.origin.x))
    frameFields["y"] = .number(Double(frame.origin.y))
    frameFields["width"] = .number(Double(frame.width))
    frameFields["height"] = .number(Double(frame.height))

    var fields: [String: JSONValue] = [:]
    fields["windowId"] = .number(Double(window.windowID))
    if let ownerPID = window.ownerPID {
        fields["ownerPid"] = .number(Double(ownerPID))
    } else {
        fields["ownerPid"] = .null
    }
    fields["ownerName"] = jsonString(window.ownerName)
    fields["bundleId"] = jsonString(window.bundleID)
    fields["title"] = jsonString(window.title)
    fields["frame"] = .object(frameFields)
    fields["layer"] = .number(Double(window.layer))
    fields["onScreen"] = .bool(window.isOnScreen)
    fields["active"] = .bool(window.isActive)
    fields["capturable"] = .bool(isCapturableWindow(window, displayFrames: displayFrames))
    fields["kind"] = .string(windowKind(window, displayFrames: displayFrames))
    fields["default"] = .bool(isDefault)
    // Accessibility-only fields stay null (not false) when the app exposes no AX
    // window for this surface, so "unknown" never reads as "no".
    fields["role"] = jsonString(accessibility?.role)
    fields["subrole"] = jsonString(accessibility?.subrole)
    if let accessibility {
        fields["minimized"] = .bool(accessibility.minimized)
    } else {
        fields["minimized"] = .null
    }
    return .object(fields)
}

func listWindowsPayload(
    _ descriptors: [WindowDescriptor],
    displayFrames: [CGRect],
    defaultWindowIDs: Set<UInt32>,
    accessibility: [UInt32: AXWindowMetadata]
) -> JSONValue {
    var entries: [JSONValue] = []
    for descriptor in descriptors {
        entries.append(windowJSON(
            descriptor,
            displayFrames: displayFrames,
            isDefault: defaultWindowIDs.contains(descriptor.windowID),
            accessibility: accessibility[descriptor.windowID]
        ))
    }
    return .object(["windows": .array(entries)])
}

// MARK: - Accessibility enrichment

/// Per-app messaging budget for window enrichment. A hung app must not stall a
/// listing that is otherwise pure WindowServer bookkeeping, and this listing is
/// read-only metadata: skipping a slow app costs three nullable fields.
let axWindowMetadataTimeoutSeconds: Float = 0.35

/// Role, subrole, and minimised state keyed by WindowServer window ID.
///
/// `AXWindowNumber` is the same identifier ScreenCaptureKit reports, which is
/// what lets the two catalogs be joined. Apps that do not expose it (some web
/// views) simply contribute nothing.
func accessibilityWindowMetadata(
    forPIDs pids: [pid_t],
    timeoutSeconds: Float = axWindowMetadataTimeoutSeconds
) -> [UInt32: AXWindowMetadata] {
    var metadata: [UInt32: AXWindowMetadata] = [:]
    for pid in Set(pids) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeoutSeconds)

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &ref
        ) == .success,
            let windows = ref as? [AXUIElement]
        else { continue }

        for window in windows {
            guard let windowID = axWindowNumber(of: window) else { continue }
            metadata[windowID] = AXWindowMetadata(
                role: axStringAttribute(window, kAXRoleAttribute as String),
                subrole: axStringAttribute(window, kAXSubroleAttribute as String),
                minimized: ElementGeometry.isMinimized(window)
            )
        }
    }
    return metadata
}

private func axWindowNumber(of window: AXUIElement) -> UInt32? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        window, "AXWindowNumber" as CFString, &ref
    ) == .success,
        let number = ref as? NSNumber
    else { return nil }
    let value = number.intValue
    guard value > 0, value <= Int(UInt32.max) else { return nil }
    return UInt32(value)
}

private func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element, attribute as CFString, &ref
    ) == .success,
        let value = ref as? String,
        !value.isEmpty
    else { return nil }
    return value
}
