@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Attribute readers

/// Read an element's AXPosition (global, top-left origin — the same coordinate
/// space CGEvent uses, so no flip math is ever required).
func elementPosition(_ element: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

/// Read an element's AXSize.
func elementSize(_ element: AXUIElement) -> CGSize? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
}

/// Read an element's AXRole.
func elementRole(_ element: AXUIElement) -> String? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref)
    guard result == .success else { return nil }
    return ref as? String
}

/// The action names an element advertises (e.g. `AXPress`).
func elementActions(_ element: AXUIElement) -> [String] {
    var ref: CFArray?
    let result = AXUIElementCopyActionNames(element, &ref)
    guard result == .success, let names = ref as? [String] else { return [] }
    return names
}

// MARK: - Coordinate math (pure, unit-testable)

/// Error thrown when an element's frame is unusable for coordinate clicking.
struct FrameGeometryError: Error {
    let message: String
}

/// Compute the center point of a frame for coordinate clicking.
///
/// Guards against a missing/zero-size frame (never click at (0,0)). Negative
/// coordinates are accepted unchanged — displays positioned left of or above the
/// main display legitimately produce global coordinates with negative values.
func clickCenter(position: CGPoint, size: CGSize) throws -> CGPoint {
    guard size.width > 0, size.height > 0 else {
        throw FrameGeometryError(message: "element has zero-size frame (\(size.width)x\(size.height))")
    }
    return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
}

// MARK: - Window resolution

/// Walk up the parent chain to the containing AXWindow. Falls back to the
/// element's AXWindow attribute if the parent chain doesn't reach a window.
func containingWindow(of element: AXUIElement) -> AXUIElement? {
    var current: AXUIElement = element
    // Bounded walk — AX trees are shallow, but guard against cycles/self-parents.
    for _ in 0..<64 {
        if elementRole(current) == (kAXWindowRole as String) {
            return current
        }
        var parentRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef)
        guard result == .success, let parent = parentRef,
              CFGetTypeID(parent) == AXUIElementGetTypeID() else {
            break
        }
        current = (parent as! AXUIElement)
    }

    // Fallback: many elements expose their containing window directly.
    var windowRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
       let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID() {
        return (window as! AXUIElement)
    }
    return nil
}

/// Whether a window is minimized (AXMinimized == true).
func isWindowMinimized(_ window: AXUIElement) -> Bool {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref)
    guard result == .success, let flag = ref as? Bool else { return false }
    return flag
}

/// The focused window of an application element, if any.
func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &ref)
    guard result == .success, let window = ref,
          CFGetTypeID(window) == AXUIElementGetTypeID() else {
        return nil
    }
    return (window as! AXUIElement)
}
