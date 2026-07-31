@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// Register the fill RPC method.
func registerFill(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable,
    glow: GlowIndicator
) {
    Task {
        await dispatcher.register(method: "fill") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue,
                  let value = obj["value"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'appHandle' or 'value'")
            }

            let strategy = FillStrategy(obj["strategy"]?.stringValue)
            let timeout = obj["timeout"]?.numberValue ?? 5.0
            let element = try await resolveTarget(
                obj: obj, appHandle: appHandle,
                appManager: appManager, handleTable: handleTable,
                timeout: timeout
            )
            try ensureElementValid(element.element)

            let connection = await appManager.get(appHandle)
            let isElectron = connection?.runtime == .electron
            let pid = connection?.pid

            let targetWindow = ElementGeometry.containingWindow(of: element.element)
            // Glow only when the window is already frontmost (background AX stays quiet).
            // Keyboard synthesis below re-presents after activate when it must foreground.
            var glowScoped = false
            defer {
                if glowScoped { Task { await glow.activityEnded() } }
            }
            if targetWindow.map(ElementGeometry.isFrontmostWindow) == true {
                await presentInteractionGlow(
                    glow: glow,
                    window: targetWindow,
                    element: element.element,
                    pointerAction: .fill,
                    scoped: &glowScoped
                )
            }

            // Check element role
            var roleRef: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(element.element, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleResult == .success) ? (roleRef as? String) : nil

            // For sliders, use AXIncrement/AXDecrement to reach the target value.
            // AXSetValue on sliders often "succeeds" without actually setting the value.
            // (Keyboard synthesis is meaningless for a slider, so this applies to every
            // strategy except an explicit keyboard override.)
            if role == (kAXSliderRole as String), let targetValue = Double(value), strategy != .keyboard {
                return try fillSlider(element: element.element, target: targetValue)
            }

            // --- AX path ---
            if strategy != .keyboard {
                let setResult = AXUIElementSetAttributeValue(
                    element.element, kAXValueAttribute as CFString, value as CFTypeRef
                )

                // In web content the AX write can "succeed" while the underlying
                // framework (React etc.) never sees an input event, so the value
                // reads back correct but app state stays stale. On Electron we always
                // follow up with keyboard synthesis in auto mode; elsewhere we trust a
                // verified read-back.
                let verified = setResult == .success && readBackMatches(element.element, expected: value)
                if strategy == .ax {
                    if verified { return .object(["success": .bool(true)]) }
                    throw RPCError.actionFailed(
                        "AX fill failed (set result: \(setResult.rawValue), value did not verify). "
                        + "Try strategy \"keyboard\".")
                }
                // strategy == .auto
                if verified && !isElectron {
                    return .object(["success": .bool(true)])
                }
            }

            // --- Keyboard synthesis path (strategy == .keyboard, or auto fallback) ---
            // Always activates the target so HID events land — outline the window we
            // just foregrounded. When the window was already frontmost the glow is up
            // from the block above; re-presenting would replay the pointer approach to
            // a point it already occupies and pay the animation delay a second time.
            await appManager.activate(appHandle)
            if !glowScoped {
                await presentInteractionGlow(
                    glow: glow,
                    window: targetWindow,
                    element: element.element,
                    pointerAction: .fill,
                    scoped: &glowScoped
                )
            }
            try await fillViaKeyboard(element.element, value: value, pid: pid)
            return .object(["success": .bool(true)])
        }
    }
}

/// How `fill` should apply text to an element.
enum FillStrategy {
    case auto      // AX write, verified; fall back to keyboard (always on Electron)
    case ax        // AX write only
    case keyboard  // keyboard synthesis only

    init(_ raw: String?) {
        switch raw {
        case "ax": self = .ax
        case "keyboard": self = .keyboard
        default: self = .auto
        }
    }
}

/// Read an element's value back and compare against the text we tried to set.
private func readBackMatches(_ element: AXUIElement, expected: String) -> Bool {
    var ref: CFTypeRef?
    let r = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref)
    guard r == .success else { return false }
    if let s = ref as? String {
        return s == expected || numericValuesMatch(s, expected)
    }
    if let n = ref as? NSNumber {
        return n.stringValue == expected || numericValuesMatch(n.stringValue, expected)
    }
    return false
}

/// Compare numeric accessibility values without treating formatting differences as failures.
private func numericValuesMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
    let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let leftValue = Double(left), let rightValue = Double(right) else { return false }
    return leftValue == rightValue
}

/// Focus the element, select-all, and type the value as synthetic key events.
/// Events are posted directly to the owning process (when known) so we don't have to
/// steal frontmost focus. Falls back to an AXPress if focusing the element fails.
private func fillViaKeyboard(_ element: AXUIElement, value: String, pid: pid_t?) async throws {
    let focusResult = AXUIElementSetAttributeValue(
        element, kAXFocusedAttribute as CFString, kCFBooleanTrue
    )
    if focusResult != .success {
        // Some web controls only take focus via a press.
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
    try await Task.sleep(for: .milliseconds(50))

    // Select all (Cmd+A) so the new value replaces any existing content.
    postKeyEvent(keyCode: keyCodeMap["a"]!, flags: .maskCommand, toPid: pid)
    try await Task.sleep(for: .milliseconds(50))

    // Type the value character by character.
    for char in value {
        typeCharacter(char, toPid: pid)
        try await Task.sleep(for: .milliseconds(10))
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
///
/// When `pid` is supplied the event is posted directly to that process
/// (`CGEvent.postToPid`) rather than the global HID tap, so input can reach a
/// background target without depending on it being frontmost — important for
/// Electron web content.
///
/// Returns whether the key-down event was created and posted. Event creation is
/// the one failure the caller can observe locally; posting itself is fire-and-forget,
/// which is why `press_key` also reads the session key-down counter for evidence.
@discardableResult
func typeCharacter(_ char: Character, toPid pid: pid_t? = nil) -> Bool {
    let str = String(char)
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return false }
    var utf16 = Array(str.utf16)
    event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    postEvent(event, toPid: pid)

    guard let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return true }
    upEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    postEvent(upEvent, toPid: pid)
    return true
}

/// Post a key event with modifiers. When `pid` is supplied the event is delivered
/// directly to that process instead of the global HID tap.
///
/// Returns whether the key-down event was created and posted.
@discardableResult
func postKeyEvent(
    keyCode: CGKeyCode, flags: CGEventFlags = CGEventFlags(), toPid pid: pid_t? = nil
) -> Bool {
    guard let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return false }
    downEvent.flags = flags
    postEvent(downEvent, toPid: pid)

    guard let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return true }
    upEvent.flags = flags
    postEvent(upEvent, toPid: pid)
    return true
}

private func postEvent(_ event: CGEvent, toPid pid: pid_t?) {
    if let pid {
        event.postToPid(pid)
    } else {
        event.post(tap: .cghidEventTap)
    }
}
