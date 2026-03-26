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

            let timeout = obj["timeout"]?.numberValue ?? 30.0
            let element = try await resolveTarget(
                obj: obj, appHandle: appHandle,
                appManager: appManager, handleTable: handleTable,
                timeout: timeout
            )

            // Try AXPress first; fall back to coordinate-based CGEvent click
            let pressResult = AXUIElementPerformAction(element.element, kAXPressAction as CFString)
            if pressResult != .success {
                guard let point = getPositionAttribute(element.element),
                      let size = getSizeAttribute(element.element) else {
                    throw RPCError.actionFailed("Click failed: AXPress unsupported and no position available")
                }

                let center = CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)

                await appManager.activate(appHandle)
                postClickEvent(at: center)
            }

            return .object(["success": .bool(true)])
        }
    }
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
