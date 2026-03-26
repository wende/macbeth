import CoreGraphics
import Foundation

private enum ParsedKeyPressKind {
    case key(code: CGKeyCode, flags: CGEventFlags)
    case text(String)
}

private struct ParsedKeyPress {
    let kind: ParsedKeyPressKind
    let delayMs: Int
}

private func parseKeyPress(_ value: JSONValue) throws -> ParsedKeyPress {
    guard let obj = value.objectValue else {
        throw RPCError.invalidParams("Each key press must be an object")
    }

    let delayMs = obj["delayMs"]?.intValue ?? 0
    guard delayMs >= 0 else {
        throw RPCError.invalidParams("'delayMs' must be >= 0")
    }

    let key = obj["key"]?.stringValue
    let text = obj["text"]?.stringValue

    switch (key, text) {
    case let (.some(key), nil):
        let modifierNames = obj["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let flags = modifierFlags(from: modifierNames)

        guard let keyCode = keyCodeMap[key.lowercased()] else {
            throw RPCError.invalidParams("Unknown key: \"\(key)\". Use lowercase key names like \"return\", \"tab\", \"a\", \"1\", etc.")
        }

        return ParsedKeyPress(kind: .key(code: keyCode, flags: flags), delayMs: delayMs)

    case let (nil, .some(text)):
        guard obj["modifiers"] == nil else {
            throw RPCError.invalidParams("'modifiers' is only supported with 'key'")
        }
        return ParsedKeyPress(kind: .text(text), delayMs: delayMs)

    default:
        throw RPCError.invalidParams("Each key press must include exactly one of 'key' or 'text'")
    }
}

/// Register the press_key RPC method.
func registerPressKey(dispatcher: Dispatcher, appManager: AppConnectionManager) {
    Task {
        await dispatcher.register(method: "press_key") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue,
                  obj["key"] != nil else {
                throw RPCError.invalidParams("Missing 'appHandle' or 'key'")
            }
            let parsed = try parseKeyPress(.object(obj))

            await appManager.activate(appHandle)
            switch parsed.kind {
            case .key(let keyCode, let flags):
                postKeyEvent(keyCode: keyCode, flags: flags)
            case .text(let text):
                for char in text {
                    typeCharacter(char)
                }
            }

            return .object(["success": .bool(true)])
        }
    }
}

/// Register the press_keys RPC method.
func registerPressKeys(dispatcher: Dispatcher, appManager: AppConnectionManager) {
    Task {
        await dispatcher.register(method: "press_keys") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue,
                  let keyValues = obj["keys"]?.arrayValue else {
                throw RPCError.invalidParams("Missing 'appHandle' or 'keys'")
            }
            guard !keyValues.isEmpty else {
                throw RPCError.invalidParams("'keys' must contain at least one key press")
            }

            let parsedKeys = try keyValues.map(parseKeyPress)

            await appManager.activate(appHandle)
            for parsed in parsedKeys {
                switch parsed.kind {
                case .key(let keyCode, let flags):
                    postKeyEvent(keyCode: keyCode, flags: flags)
                case .text(let text):
                    for char in text {
                        typeCharacter(char)
                    }
                }
                if parsed.delayMs > 0 {
                    try await Task.sleep(for: .milliseconds(parsed.delayMs))
                }
            }

            return .object([
                "success": .bool(true),
                "count": .number(Double(parsedKeys.count)),
            ])
        }
    }
}
