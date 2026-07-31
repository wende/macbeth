@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - Outcome vocabulary

/// How far a keyboard call got.
///
/// The tiers are cumulative, and deliberately additive: `attempted` does not mean
/// "nothing happened" — it means macbeth could not establish that the events entered
/// the system event stream. `verified` is reserved for post-action effect
/// verification and is never produced yet; see
/// `docs/keyboard-input-and-foregrounding.md`.
enum KeyDispatchOutcome: String, Sendable, Equatable {
    /// Events were requested but their arrival in the event stream is unconfirmed.
    case attempted
    /// Events entered the system event stream. Whether the app acted on them is unknown.
    case dispatched
    /// The app's observable state changed as a result. Not produced yet.
    case verified
}

/// Machine-readable warning codes attached to a keyboard dispatch.
///
/// Warnings never fail a call — they annotate an otherwise normal result so an
/// agent can tell "sent, unverified" from "probably went somewhere else".
enum KeyDispatchWarning: String, Sendable, Equatable {
    /// No key events could be created; nothing was sent.
    case dispatchFailed = "dispatch-failed"
    /// Some, but not all, of the requested events could be created.
    case dispatchIncomplete = "dispatch-incomplete"
    /// Events were posted but the session key-down counter did not advance.
    case dispatchUnconfirmed = "dispatch-unconfirmed"
    /// The counter advanced by less than the number of events posted.
    case dispatchPartiallyConfirmed = "dispatch-partially-confirmed"
    /// macbethd is not trusted for Accessibility, so macOS drops synthetic events.
    case accessibilityNotTrusted = "accessibility-not-trusted"
    /// The target app did not hold keyboard focus when the events were posted.
    case targetNotFrontmost = "target-not-frontmost"
    /// The target app exposes no focused AX element.
    case noFocusedElement = "no-focused-element"
    /// The app handle no longer resolves to a connection.
    case appHandleUnknown = "app-handle-unknown"
}

/// The classification of a keyboard dispatch plus the prose that explains it.
struct KeyDispatchDiagnosis: Sendable, Equatable {
    let outcome: KeyDispatchOutcome
    let warnings: [String]
    let note: String
}

/// Classify a keyboard dispatch from the evidence gathered around it.
///
/// Pure by design: every input is a plain value so the classification is unit
/// testable without a window server, a focused app, or Accessibility permission.
///
/// - Parameters:
///   - requestedKeyDowns: Key-down events the call asked for.
///   - postedKeyDowns: Key-down events that were actually created and posted.
///   - sessionKeyDownDelta: How far the session key-down counter advanced across
///     the dispatch, or nil when no counter reading was available. Real user
///     typing can inflate this, so it confirms dispatch (`>=`) and never refutes it.
///   - accessibilityTrusted: Whether the daemon is trusted for Accessibility.
///   - targetFrontmost: Whether the target app held keyboard focus at dispatch time.
///   - hasFocusedElement: Whether the target app exposed a focused AX element.
func diagnoseKeyDispatch(
    requestedKeyDowns: Int,
    postedKeyDowns: Int,
    sessionKeyDownDelta: Int?,
    accessibilityTrusted: Bool,
    targetFrontmost: Bool,
    hasFocusedElement: Bool
) -> KeyDispatchDiagnosis {
    var warnings: [KeyDispatchWarning] = []
    var notes: [String] = []
    let outcome: KeyDispatchOutcome

    if postedKeyDowns <= 0 {
        outcome = .attempted
        warnings.append(.dispatchFailed)
        notes.append(
            "No keyboard events could be created, so nothing was sent to the system.")
    } else {
        if postedKeyDowns < requestedKeyDowns {
            warnings.append(.dispatchIncomplete)
            notes.append(
                "Only \(postedKeyDowns) of \(requestedKeyDowns) key events could be created.")
        }

        switch sessionKeyDownDelta {
        case .some(let delta) where delta >= postedKeyDowns:
            outcome = .dispatched
        case .some(let delta) where delta > 0:
            outcome = .dispatched
            warnings.append(.dispatchPartiallyConfirmed)
            notes.append(
                "The session key-down counter advanced by \(delta) for \(postedKeyDowns) "
                + "posted events, so part of the sequence is unconfirmed.")
        case .some:
            outcome = .attempted
            warnings.append(.dispatchUnconfirmed)
            notes.append(
                "The events were posted but the session key-down counter did not advance, "
                + "so they may never have entered the event stream.")
        case .none:
            outcome = .attempted
            warnings.append(.dispatchUnconfirmed)
            notes.append(
                "The events were posted but no dispatch evidence was available.")
        }
    }

    if !accessibilityTrusted {
        warnings.append(.accessibilityNotTrusted)
        notes.append(
            "macbethd is not trusted for Accessibility — macOS drops synthetic key events "
            + "from untrusted processes. Grant access in System Settings → Privacy & "
            + "Security → Accessibility, then fully quit and relaunch the launching app.")
    }
    if !targetFrontmost {
        warnings.append(.targetNotFrontmost)
        notes.append(
            "The target app did not hold keyboard focus when the events were posted, "
            + "so another app may have received them.")
    }
    if !hasFocusedElement {
        warnings.append(.noFocusedElement)
        notes.append(
            "The target app reports no focused element. Many apps still handle keys at "
            + "window level, so this alone does not mean the keystroke was lost.")
    }

    switch outcome {
    case .dispatched:
        notes.insert(
            "Keyboard events entered the system event stream. Whether the app acted on "
            + "them is not verified.",
            at: 0)
    case .attempted:
        notes.insert("Dispatch could not be confirmed.", at: 0)
        notes.append(
            "Do not resend blindly — confirm the current state with query_tree, wait_for, "
            + "or screenshot first.")
    case .verified:
        notes.insert("The app's observable state changed after the keystroke.", at: 0)
    }

    return KeyDispatchDiagnosis(
        outcome: outcome,
        warnings: warnings.map(\.rawValue),
        note: notes.joined(separator: " ")
    )
}

// MARK: - Dispatch evidence

/// Session-wide count of key-down events, used as before/after dispatch evidence.
///
/// This counts events entering the session event stream, including events other
/// processes (or a human at the keyboard) generate — which is why the delta is only
/// ever read as confirmation, never as a refutation of a larger expected count.
/// Normalised to `UInt32` so the wrap-safe delta below stays exact regardless of
/// the counter's platform width.
func sessionKeyDownCounter() -> UInt32 {
    UInt32(
        truncatingIfNeeded: CGEventSource.counterForEventType(
            .combinedSessionState, eventType: .keyDown
        )
    )
}

/// Wrap-safe delta between two readings of `sessionKeyDownCounter()`.
func sessionKeyDownDelta(before: UInt32, after: UInt32) -> Int {
    Int(after &- before)
}

/// How long to let the event system settle before reading the counter back.
///
/// Posting is asynchronous with respect to the counter, so an immediate read can
/// miss the last event and report a good press as unconfirmed. Small enough to be
/// lost in the activation poll that already precedes every keyboard dispatch.
let keyDispatchSettleMs = 20

// MARK: - Target identification

/// The focused AX element in the target app at dispatch time.
struct KeyFocusedElement: Sendable, Equatable {
    let role: String?
    let subrole: String?
    let title: String?
    let identifier: String?
    let value: String?
}

/// Who was addressed by a keyboard dispatch, and who actually held keyboard focus.
struct KeyTargetSnapshot: Sendable, Equatable {
    let appName: String?
    let pid: pid_t?
    let bundleId: String?
    let frontmost: Bool
    let focusedAppPid: pid_t?
    let focusedAppName: String?
    let windowTitle: String?
    let windowIdentity: String?
    let focusedElement: KeyFocusedElement?

    static let unknown = KeyTargetSnapshot(
        appName: nil, pid: nil, bundleId: nil, frontmost: false,
        focusedAppPid: nil, focusedAppName: nil,
        windowTitle: nil, windowIdentity: nil, focusedElement: nil
    )
}

/// AX value strings can be whole documents. Keep the report readable.
private let focusedValueLimit = 120

/// Capture what can be established about the keyboard target, immediately before
/// events are posted. Every field is best-effort: an app that exposes nothing
/// through AX yields a snapshot of nils rather than an error.
func captureKeyTargetSnapshot(
    pid: pid_t,
    appName: String?,
    bundleId: String?,
    window: AXUIElement?
) -> KeyTargetSnapshot {
    let focusedAppPid = systemWideFocusedApplicationPid()
    let runningApp = NSRunningApplication(processIdentifier: pid)
    // Lenient on purpose: either signal saying the target has focus is enough, so a
    // race in one of them cannot produce a spurious "went to the wrong app" warning.
    let frontmost = focusedAppPid == pid || runningApp?.isActive == true

    let appElement = AXUIElementCreateApplication(pid)
    let focusedElement = copyFocusedElement(of: appElement).map(describeFocusedElement)

    return KeyTargetSnapshot(
        appName: appName ?? runningApp?.localizedName,
        pid: pid,
        bundleId: bundleId ?? runningApp?.bundleIdentifier,
        frontmost: frontmost,
        focusedAppPid: focusedAppPid,
        focusedAppName: focusedAppPid.flatMap {
            NSRunningApplication(processIdentifier: $0)?.localizedName
        },
        windowTitle: window.flatMap { getStringAttribute($0, kAXTitleAttribute) },
        windowIdentity: window.map { ElementGeometry.windowIdentity(of: $0) },
        focusedElement: focusedElement
    )
}

private func systemWideFocusedApplicationPid() -> pid_t? {
    let systemWide = AXUIElementCreateSystemWide()
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        systemWide, kAXFocusedApplicationAttribute as CFString, &ref
    ) == .success,
        let value = ref,
        CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }

    var pid: pid_t = 0
    guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success else { return nil }
    return pid
}

private func copyFocusedElement(of application: AXUIElement) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        application, kAXFocusedUIElementAttribute as CFString, &ref
    ) == .success,
        let value = ref,
        CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
}

private func describeFocusedElement(_ element: AXUIElement) -> KeyFocusedElement {
    KeyFocusedElement(
        role: getStringAttribute(element, kAXRoleAttribute),
        subrole: getStringAttribute(element, kAXSubroleAttribute),
        title: getStringAttribute(element, kAXTitleAttribute),
        identifier: getStringAttribute(element, kAXIdentifierAttribute),
        value: getValueAsString(element).map(truncateFocusedValue)
    )
}

/// Exposed for tests: keep long AX values from swamping the result payload.
func truncateFocusedValue(_ value: String) -> String {
    guard value.count > focusedValueLimit else { return value }
    return String(value.prefix(focusedValueLimit)) + "…"
}

// MARK: - JSON

extension KeyFocusedElement {
    var json: JSONValue {
        .object([
            "role": role.map(JSONValue.string) ?? .null,
            "subrole": subrole.map(JSONValue.string) ?? .null,
            "title": title.map(JSONValue.string) ?? .null,
            "identifier": identifier.map(JSONValue.string) ?? .null,
            "value": value.map(JSONValue.string) ?? .null,
        ])
    }
}

extension KeyTargetSnapshot {
    var json: JSONValue {
        .object([
            "app": appName.map(JSONValue.string) ?? .null,
            "pid": pid.map { JSONValue.number(Double($0)) } ?? .null,
            "bundleId": bundleId.map(JSONValue.string) ?? .null,
            "frontmost": .bool(frontmost),
            "focusedApp": .object([
                "pid": focusedAppPid.map { JSONValue.number(Double($0)) } ?? .null,
                "name": focusedAppName.map(JSONValue.string) ?? .null,
            ]),
            "window": .object([
                "title": windowTitle.map(JSONValue.string) ?? .null,
                "identity": windowIdentity.map(JSONValue.string) ?? .null,
            ]),
            "focusedElement": focusedElement?.json ?? .null,
        ])
    }
}

/// Build the `press_key` / `press_keys` result payload.
///
/// `success` stays in the payload for older clients, and keeps its original
/// meaning: the call did something. It is false only when no event could be
/// created at all.
func keyDispatchResultJSON(
    diagnosis: KeyDispatchDiagnosis,
    requestedKeyDowns: Int,
    postedKeyDowns: Int,
    sessionKeyDownDelta: Int?,
    accessibilityTrusted: Bool,
    target: KeyTargetSnapshot,
    extraWarnings: [String] = [],
    extra: [String: JSONValue] = [:]
) -> JSONValue {
    var payload: [String: JSONValue] = [
        "success": .bool(postedKeyDowns > 0),
        "outcome": .string(diagnosis.outcome.rawValue),
        "dispatched": .bool(diagnosis.outcome != .attempted),
        "verified": .bool(diagnosis.outcome == .verified),
        "note": .string(diagnosis.note),
        "warnings": .array((extraWarnings + diagnosis.warnings).map(JSONValue.string)),
        "keysRequested": .number(Double(requestedKeyDowns)),
        "keysPosted": .number(Double(postedKeyDowns)),
        "evidence": .object([
            "sessionKeyDownDelta": sessionKeyDownDelta.map { JSONValue.number(Double($0)) } ?? .null,
            "accessibilityTrusted": .bool(accessibilityTrusted),
        ]),
        "target": target.json,
    ]
    for (key, value) in extra {
        payload[key] = value
    }
    return .object(payload)
}
