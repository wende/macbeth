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
