@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// Register the click RPC method.
func registerClick(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable
) {
    Task {
        await dispatcher.register(method: "click") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'appHandle'")
            }

            let strategy = ClickStrategy(obj["strategy"]?.stringValue)
            let timeout = obj["timeout"]?.numberValue ?? 5.0
            let element = try await resolveTarget(
                obj: obj, appHandle: appHandle,
                appManager: appManager, handleTable: handleTable,
                timeout: timeout
            )
            try ensureElementValid(element.element)

            // --- AX press path ---
            if strategy != .mouse {
                if performPress(element.element) {
                    return .object(["success": .bool(true)])
                }
                if strategy == .ax {
                    throw RPCError.actionFailed(
                        "AXPress unsupported on the element and its immediate neighbours. "
                        + "Try strategy \"mouse\".")
                }
            }

            // --- Coordinate-based mouse fallback (strategy == .mouse, or auto fallback) ---
            guard let point = getPositionAttribute(element.element),
                  let size = getSizeAttribute(element.element),
                  size.width > 0, size.height > 0 else {
                throw RPCError.actionFailed(
                    "Click failed: AXPress unsupported and no usable position/size for a mouse fallback")
            }

            let center = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
            await appManager.activate(appHandle)
            postClickEvent(at: center)

            return .object(["success": .bool(true)])
        }
    }
}

// MARK: - Strategy

/// How `click` should activate an element.
enum ClickStrategy {
    case auto   // AXPress (with neighbour lookup); fall back to a synthetic mouse click
    case ax     // AXPress only (element or an adjacent node)
    case mouse  // synthetic mouse click at the element's centre

    init(_ raw: String?) {
        switch raw {
        case "ax": self = .ax
        case "mouse": self = .mouse
        default: self = .auto
        }
    }
}

/// Try to AXPress the element. In web content the pressable action often lives on an
/// adjacent node (inner div vs. button), so if the element itself doesn't advertise
/// AXPress we look one level up (parent) and one level down (first child).
/// Returns true if a press succeeded.
private func performPress(_ element: AXUIElement) -> Bool {
    if supportsPress(element) {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
    }

    // Chromium sometimes puts the action on a neighbouring node.
    var candidates: [AXUIElement] = []
    if let parent = copyElementAttribute(element, kAXParentAttribute) {
        candidates.append(parent)
    }
    if let firstChild = getChildElements(element).first {
        candidates.append(firstChild)
    }

    for candidate in candidates where supportsPress(candidate) {
        if AXUIElementPerformAction(candidate, kAXPressAction as CFString) == .success {
            return true
        }
    }

    // Last resort within the AX path: press the element directly even if it didn't
    // advertise the action (some elements under-report their action names).
    return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}

/// Whether an element lists AXPress among its supported actions.
private func supportsPress(_ element: AXUIElement) -> Bool {
    var namesRef: CFArray?
    guard AXUIElementCopyActionNames(element, &namesRef) == .success,
          let names = namesRef as? [String] else { return false }
    return names.contains(kAXPressAction as String)
}

private func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
          let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func getChildElements(_ element: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
          let children = ref as? [AXUIElement] else { return [] }
    return children
}

// MARK: - Coordinate-based click helpers

private func getPositionAttribute(_ element: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

private func getSizeAttribute(_ element: AXUIElement) -> CGSize? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
}

private func postClickEvent(at point: CGPoint) {
    let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    mouseDown?.post(tap: .cghidEventTap)
    usleep(80_000)
    mouseUp?.post(tap: .cghidEventTap)
}
