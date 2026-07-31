@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

private enum ParsedKeyPressKind {
    case key(code: CGKeyCode, flags: CGEventFlags)
    case text(String)
}

private struct ParsedKeyPress {
    let kind: ParsedKeyPressKind
    let delayMs: Int

    /// Key-down events this item asks for: one per key, one per character of text.
    var keyDownCount: Int {
        switch kind {
        case .key: return 1
        case .text(let text): return text.count
        }
    }
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
func registerPressKey(dispatcher: Dispatcher, appManager: AppConnectionManager, glow: GlowIndicator) {
    Task {
        await dispatcher.register(method: "press_key") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue,
                  obj["key"] != nil else {
                throw RPCError.invalidParams("Missing 'appHandle' or 'key'")
            }
            let parsed = try parseKeyPress(.object(obj))

            let connection = try await requireConnection(appHandle, appManager)
            let targetWindow = ElementGeometry.preferredWindow(of: connection.appElement.element)
            // press_key always activates the target so HID events land — outline
            // after activate so background-to-front paths get honest chrome.
            var glowScoped = false
            defer {
                if glowScoped { Task { await glow.activityEnded() } }
            }

            await appManager.activate(appHandle)
            await presentInteractionGlow(
                glow: glow,
                window: targetWindow,
                scoped: &glowScoped
            )

            return try await dispatchAndReport(
                strokes: [parsed],
                connection: connection,
                targetWindow: targetWindow
            )
        }
    }
}

/// Register the press_keys RPC method.
func registerPressKeys(dispatcher: Dispatcher, appManager: AppConnectionManager, glow: GlowIndicator) {
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

            let connection = try await requireConnection(appHandle, appManager)
            let targetWindow = ElementGeometry.preferredWindow(of: connection.appElement.element)
            var glowScoped = false
            defer {
                if glowScoped { Task { await glow.activityEnded() } }
            }

            await appManager.activate(appHandle)
            await presentInteractionGlow(
                glow: glow,
                window: targetWindow,
                scoped: &glowScoped
            )
            return try await dispatchAndReport(
                strokes: parsedKeys,
                connection: connection,
                targetWindow: targetWindow,
                extra: ["count": .number(Double(parsedKeys.count))]
            )
        }
    }
}

// MARK: - Dispatch + reporting

/// Post a parsed key sequence and report what could actually be established about it.
///
/// The dispatch itself is unchanged from the original fire-and-forget path: every
/// stroke is posted the same way, in the same order, with the same delays. Only the
/// bookkeeping around it is new — a target snapshot taken just before the first
/// event, a session key-down counter read on both sides, and the per-event
/// creation results. Nothing here can prevent a keystroke from being sent.
private func dispatchAndReport(
    strokes: [ParsedKeyPress],
    connection: AppConnectionManager.Connection,
    targetWindow: AXUIElement?,
    extra: [String: JSONValue] = [:]
) async throws -> JSONValue {
    let requested = strokes.reduce(0) { $0 + $1.keyDownCount }
    let target = captureKeyTargetSnapshot(
        pid: connection.pid,
        appName: connection.appName,
        bundleId: connection.bundleId,
        window: targetWindow
    )

    let counterBefore = sessionKeyDownCounter()
    var posted = 0
    var dangling = 0

    for stroke in strokes {
        switch stroke.kind {
        case .key(let keyCode, let flags):
            let result = postKeyEvent(keyCode: keyCode, flags: flags)
            if result.downPosted { posted += 1 }
            if result.isDangling { dangling += 1 }
        case .text(let text):
            for char in text {
                let result = typeCharacter(char)
                if result.downPosted { posted += 1 }
                if result.isDangling { dangling += 1 }
            }
        }
        if stroke.delayMs > 0 {
            try await Task.sleep(for: .milliseconds(stroke.delayMs))
        }
    }

    try? await Task.sleep(for: .milliseconds(keyDispatchSettleMs))
    let delta = sessionKeyDownDelta(before: counterBefore, after: sessionKeyDownCounter())
    let trusted = checkAccessibilityPermissions()
    let diagnosis = diagnoseKeyDispatch(
        requestedKeyDowns: requested,
        postedKeyDowns: posted,
        danglingKeyDowns: dangling,
        sessionKeyDownDelta: delta,
        accessibilityTrusted: trusted,
        targetFrontmost: target.frontmost,
        hasFocusedElement: target.focusedElement != nil
    )

    return keyDispatchResultJSON(
        diagnosis: diagnosis,
        requestedKeyDowns: requested,
        postedKeyDowns: posted,
        sessionKeyDownDelta: delta,
        accessibilityTrusted: trusted,
        target: target,
        extra: extra
    )
}

/// Resolve the app handle, or refuse to type.
///
/// Every other method rejects an unresolvable handle (`wait_for`, `click`, …), and
/// keyboard input is the one place where continuing is actively harmful: with no
/// connection there is nothing to activate, so the events land in whatever app the
/// user is currently in. Refusing is the honest answer to "send this to that app"
/// when that app cannot be found.
private func requireConnection(
    _ appHandle: String, _ appManager: AppConnectionManager
) async throws -> AppConnectionManager.Connection {
    guard let connection = await appManager.get(appHandle) else {
        throw RPCError.appNotFound(
            "Invalid or expired app handle: \(appHandle). Reconnect with connect_app — "
            + "keyboard input is not sent without a resolvable target, because it would "
            + "reach whichever app is frontmost instead.")
    }
    return connection
}
