@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// Register the fill RPC method.
func registerFill(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable
) {
    Task {
        await dispatcher.register(method: "fill") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue,
                  let value = obj["value"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'appHandle' or 'value'")
            }

            let timeout = obj["timeout"]?.numberValue ?? 5.0
            let element = try await resolveTarget(
                obj: obj, appHandle: appHandle,
                appManager: appManager, handleTable: handleTable,
                timeout: timeout
            )

            // Check element role
            var roleRef: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(element.element, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleResult == .success) ? (roleRef as? String) : nil

            // For sliders, use AXIncrement/AXDecrement to reach the target value.
            // AXSetValue on sliders often "succeeds" without actually setting the value.
            if role == (kAXSliderRole as String), let targetValue = Double(value) {
                return try fillSlider(element: element.element, target: targetValue)
            }

            // For non-slider elements: try direct AX value setting
            let setResult = AXUIElementSetAttributeValue(
                element.element, kAXValueAttribute as CFString, value as CFTypeRef
            )

            if setResult == .success {
                return .object(["success": .bool(true)])
            }

            // Fallback: focus, select all, type the value
            await appManager.activate(appHandle)
            AXUIElementSetAttributeValue(
                element.element, kAXFocusedAttribute as CFString, true as CFTypeRef
            )
            try await Task.sleep(for: .milliseconds(50))

            // Select all (Cmd+A)
            postKeyEvent(keyCode: keyCodeMap["a"]!, flags: .maskCommand)
            try await Task.sleep(for: .milliseconds(50))

            // Type the value character by character
            for char in value {
                typeCharacter(char)
                try await Task.sleep(for: .milliseconds(10))
            }

            return .object(["success": .bool(true)])
        }
    }
}

/// Fill a slider using AXIncrement/AXDecrement to get close, then AXSetValue (+1) to fine-tune.
/// AXIncrement/AXDecrement change by the slider's step size (often 10).
/// AXSetValue always increments by exactly 1 regardless of the value passed.
private func fillSlider(element: AXUIElement, target: Double) throws -> JSONValue {
    func readValue() -> Double? {
        var ref: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref)
        guard r == .success else { return nil }
        if let n = ref as? NSNumber { return n.doubleValue }
        if let s = ref as? String, let d = Double(s) { return d }
        return nil
    }

    guard var current = readValue() else {
        throw RPCError.actionFailed("Cannot read slider value")
    }

    let roundedTarget = target.rounded()
    if abs(roundedTarget - current) < 0.5 {
        return .object(["success": .bool(true), "value": .number(current)])
    }

    // Phase 1: Use AXDecrement to get below target (or AXIncrement if already below)
    // Then Phase 2: AXSetValue (+1 each) to reach exact target from below
    let maxSteps = 200

    // First, get at or below the target using AXDecrement
    for _ in 0..<maxSteps {
        if current <= roundedTarget { break }
        let r = AXUIElementPerformAction(element, kAXDecrementAction as CFString)
        if r != .success { break }
        guard let v = readValue(), v != current else { break }
        current = v
    }

    // If still above target (stuck), return what we have
    if current > roundedTarget {
        return .object(["success": .bool(true), "value": .number(current)])
    }

    // If below target, use AXIncrement to get closer (but not past)
    for _ in 0..<maxSteps {
        if current >= roundedTarget { break }
        // Peek: would increment overshoot?
        let r = AXUIElementPerformAction(element, kAXIncrementAction as CFString)
        if r != .success { break }
        guard let v = readValue(), v != current else { break }
        if v > roundedTarget {
            // Overshot — undo with decrement
            AXUIElementPerformAction(element, kAXDecrementAction as CFString)
            current = readValue() ?? current
            break
        }
        current = v
    }

    // Phase 2: Fine-tune with AXSetValue (+1 each call) to reach exact target
    for _ in 0..<maxSteps {
        if abs(current - roundedTarget) < 0.5 { break }
        if current >= roundedTarget { break }
        // AXSetValue on Logic Pro sliders always adds +1 regardless of the value
        let r = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, NSNumber(value: roundedTarget) as CFTypeRef)
        if r != .success { break }
        guard let v = readValue(), v != current else { break }
        current = v
    }

    return .object(["success": .bool(true), "value": .number(current)])
}

/// Type a single character via CGEvent.
func typeCharacter(_ char: Character) {
    let str = String(char)
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return }
    var utf16 = Array(str.utf16)
    event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    event.post(tap: .cghidEventTap)

    guard let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
    upEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    upEvent.post(tap: .cghidEventTap)
}

/// Post a key event with modifiers.
func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags = CGEventFlags()) {
    guard let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
    downEvent.flags = flags
    downEvent.post(tap: .cghidEventTap)

    guard let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
    upEvent.flags = flags
    upEvent.post(tap: .cghidEventTap)
}
