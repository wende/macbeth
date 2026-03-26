import CoreGraphics
import Foundation

/// Register the press_key RPC method.
func registerPressKey(dispatcher: Dispatcher) {
    Task {
        await dispatcher.register(method: "press_key") { params in
            guard let obj = params?.objectValue,
                  let key = obj["key"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'key'")
            }

            let modifierNames = obj["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let flags = modifierFlags(from: modifierNames)

            guard let keyCode = keyCodeMap[key.lowercased()] else {
                throw RPCError.invalidParams("Unknown key: \"\(key)\". Use lowercase key names like \"return\", \"tab\", \"a\", \"1\", etc.")
            }

            postKeyEvent(keyCode: keyCode, flags: flags)

            return .object(["success": .bool(true)])
        }
    }
}
