@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// Register the click RPC method.
func registerClick(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable,
    glow: GlowIndicator
) {
    Task {
        await dispatcher.register(method: "click") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'appHandle'")
            }

            let strategy = ClickStrategy(obj["strategy"]?.stringValue)
            let waitForIdleMs = obj["waitForIdleMs"]?.numberValue ?? 0
            let timeout = obj["timeout"]?.numberValue ?? 5.0
            let element = try await resolveTarget(
                obj: obj, appHandle: appHandle,
                appManager: appManager, handleTable: handleTable,
                timeout: timeout
            )
            try ensureElementValid(element.element)

            // Only present an interaction overlay for the exact window the
            // user is currently looking at. Background AX work remains quiet.
            let targetWindow = ElementGeometry.containingWindow(of: element.element)
            let showGlow = targetWindow.map(ElementGeometry.isFrontmostWindow) ?? false
            if showGlow { await glow.activityStarted() }
            defer {
                if showGlow { Task { await glow.activityEnded() } }
            }
            if showGlow, let window = targetWindow,
               let frame = ElementGeometry.frame(of: window) {
                await glow.windowFocused(id: ElementGeometry.windowIdentity(of: window), frame: frame)
            }
            if showGlow,
               let point = ElementGeometry.interactionPoint(of: element.element),
               await glow.pointerMoved(to: point, action: .click) {
                try? await Task.sleep(for: .milliseconds(470))
            }

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

            // --- Safe coordinate fallback (strategy == .mouse, or auto fallback) ---
            guard let connection = await appManager.get(appHandle) else {
                throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
            }
            do {
                try await performSafeMouseClick(
                    element: element.element,
                    targetPid: connection.pid,
                    waitForIdleMs: waitForIdleMs
                )
            } catch let error as SafeMouseClickError {
                throw RPCError.actionFailed(error.message)
            }

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
    let elementSupportsPress = supportsPress(element)
    if elementSupportsPress {
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
    if !elementSupportsPress {
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
    return false
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
