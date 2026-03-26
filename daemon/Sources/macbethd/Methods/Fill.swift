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

            let timeout = obj["timeout"]?.numberValue ?? 30.0
            let element = try await resolveTarget(
                obj: obj, appHandle: appHandle,
                appManager: appManager, handleTable: handleTable,
                timeout: timeout
            )

            // Try direct AX value setting first
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
