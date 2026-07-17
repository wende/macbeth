@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

enum ElementGeometry {
    enum GeometryError: Error, Equatable {
        case unusableFrame
    }

    static func position(of element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &ref
        ) == .success,
            let value = ref,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(of element: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &ref
        ) == .success,
            let value = ref,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    static func center(position: CGPoint, size: CGSize) throws -> CGPoint {
        guard size.width > 0, size.height > 0,
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite else {
            throw GeometryError.unusableFrame
        }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        if let window = elementAttribute(element, kAXWindowAttribute) {
            return window
        }

        var current = element
        for _ in 0..<32 {
            if role(of: current) == (kAXWindowRole as String) {
                return current
            }
            guard let parent = elementAttribute(current, kAXParentAttribute) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    static func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        elementAttribute(application, kAXFocusedWindowAttribute)
    }

    static func preferredWindow(of application: AXUIElement) -> AXUIElement? {
        if let focused = focusedWindow(of: application) { return focused }
        if let main = elementAttribute(application, kAXMainWindowAttribute) { return main }

        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &ref
        ) == .success,
            let windows = ref as? [AXUIElement]
        else { return nil }
        return windows.first(where: { !isMinimized($0) }) ?? windows.first
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = position(of: element), let size = size(of: element),
              size.width > 0, size.height > 0,
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func preferredWindowFrame(of application: AXUIElement) -> CGRect? {
        guard let window = preferredWindow(of: application) else { return nil }
        return frame(of: window)
    }

    /// Stable identity shared with CoreGraphics/ScreenCaptureKit whenever the
    /// accessibility provider exposes AXWindowNumber. CFHash is a process-local
    /// fallback for providers (notably some web views) that omit it.
    static func windowIdentity(of window: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)

        var numberRef: CFTypeRef?
        let numberResult = AXUIElementCopyAttributeValue(
            window, "AXWindowNumber" as CFString, &numberRef
        )
        if numberResult == .success, let number = numberRef as? NSNumber {
            return windowIdentity(pid: pid, windowNumber: number.intValue)
        }
        return "pid:\(pid):ax:\(CFHash(window))"
    }

    static func windowIdentity(pid: pid_t, windowNumber: Int) -> String {
        "pid:\(pid):window:\(windowNumber)"
    }

    static func interactionPoint(of element: AXUIElement) -> CGPoint? {
        guard let elementFrame = frame(of: element) else { return nil }
        let point = CGPoint(x: elementFrame.midX, y: elementFrame.midY)
        guard let window = containingWindow(of: element),
              let windowFrame = frame(of: window),
              isPlausibleInteraction(point: point, inside: windowFrame) else {
            return nil
        }
        return point
    }

    static func isPlausibleInteraction(point: CGPoint, inside windowFrame: CGRect) -> Bool {
        guard point.x.isFinite, point.y.isFinite,
              windowFrame.width > 0, windowFrame.height > 0 else { return false }
        // A small allowance covers shadows, title-bar controls, and controls in
        // sheets while rejecting synthetic AX frames at the global origin.
        return windowFrame.insetBy(dx: -80, dy: -80).contains(point)
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXMinimizedAttribute as CFString, &ref
        ) == .success else { return false }
        return (ref as? Bool) ?? false
    }

    private static func elementAttribute(
        _ element: AXUIElement, _ attribute: String
    ) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &ref
        ) == .success,
            let value = ref,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func role(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &ref
        ) == .success else { return nil }
        return ref as? String
    }
}
