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
/// verification and is not yet produced; see
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
    /// A key-down was posted whose matching key-up could not be created.
    case keyUpNotPosted = "key-up-not-posted"
    /// macbethd is not trusted for Accessibility, so macOS drops synthetic events.
    case accessibilityNotTrusted = "accessibility-not-trusted"
    /// The target app did not hold keyboard focus when the events were posted.
    case targetNotFrontmost = "target-not-frontmost"
    /// The target app exposes no focused AX element.
    case noFocusedElement = "no-focused-element"
}

/// The result of posting one key-down / key-up pair.
///
/// The halves are tracked separately because they fail independently: a key-down
/// whose key-up could not be created still reached the system, and leaves the key
/// logically held. Collapsing that into a single boolean either hides a stuck key
/// or claims nothing was sent when something was.
struct KeyEventPost: Sendable, Equatable {
    let downPosted: Bool
    let upPosted: Bool

    static let nothingPosted = KeyEventPost(downPosted: false, upPosted: false)
    static let complete = KeyEventPost(downPosted: true, upPosted: true)

    /// A key-down that reached the system with no matching key-up.
    var isDangling: Bool { downPosted && !upPosted }
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
///   - danglingKeyDowns: Key-downs posted without a matching key-up.
///   - sessionKeyDownDelta: How far the session key-down counter advanced across
///     the dispatch, or nil when no counter reading was available. Real user
///     typing can inflate this, so it confirms dispatch (`>=`) and never refutes it.
///   - accessibilityTrusted: Whether the daemon is trusted for Accessibility.
///   - targetFrontmost: Whether the target app held keyboard focus at dispatch time.
///   - hasFocusedElement: Whether the target app exposed a focused AX element.
func diagnoseKeyDispatch(
    requestedKeyDowns: Int,
    postedKeyDowns: Int,
    danglingKeyDowns: Int = 0,
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
            // Partial confirmation is not dispatch: with 5 events posted and a delta
            // of 1, four of them may never have entered the event stream. Claiming
            // `dispatched` there would overstate exactly what this tier exists to pin
            // down, so the outcome stays `attempted` and the count goes in the note.
            outcome = .attempted
            warnings.append(.dispatchPartiallyConfirmed)
            notes.append(
                "The session key-down counter advanced by \(delta) for \(postedKeyDowns) "
                + "posted events, so most of the sequence is unconfirmed.")
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

    if danglingKeyDowns > 0 {
        warnings.append(.keyUpNotPosted)
        notes.append(
            "\(danglingKeyDowns) key-down event(s) reached the system without a matching "
            + "key-up, so a key or modifier may still be held down. Send the key again "
            + "to clear it if the app starts behaving as though a key is stuck.")
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

// Optional-to-JSON helpers, and dictionaries assembled key by key. Swift's type
// checker times out on a nested literal that mixes `map`/`??` conversions inline
// (it has to consider every JSONValue overload for every entry at once).

private func jsonText(_ value: String?) -> JSONValue {
    guard let value else { return .null }
    return .string(value)
}

private func jsonCount(_ value: Int?) -> JSONValue {
    guard let value else { return .null }
    return .number(Double(value))
}

private func jsonPid(_ value: pid_t?) -> JSONValue {
    guard let value else { return .null }
    return .number(Double(value))
}

extension KeyFocusedElement {
    var json: JSONValue {
        var fields: [String: JSONValue] = [:]
        fields["role"] = jsonText(role)
        fields["subrole"] = jsonText(subrole)
        fields["title"] = jsonText(title)
        fields["identifier"] = jsonText(identifier)
        fields["value"] = jsonText(value)
        return .object(fields)
    }
}

extension KeyTargetSnapshot {
    var json: JSONValue {
        var focusedApp: [String: JSONValue] = [:]
        focusedApp["pid"] = jsonPid(focusedAppPid)
        focusedApp["name"] = jsonText(focusedAppName)

        var window: [String: JSONValue] = [:]
        window["title"] = jsonText(windowTitle)
        window["identity"] = jsonText(windowIdentity)

        var fields: [String: JSONValue] = [:]
        fields["app"] = jsonText(appName)
        fields["pid"] = jsonPid(pid)
        fields["bundleId"] = jsonText(bundleId)
        fields["frontmost"] = .bool(frontmost)
        fields["focusedApp"] = .object(focusedApp)
        fields["window"] = .object(window)
        fields["focusedElement"] = focusedElement?.json ?? .null
        return .object(fields)
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
    extra: [String: JSONValue] = [:]
) -> JSONValue {
    var evidence: [String: JSONValue] = [:]
    evidence["sessionKeyDownDelta"] = jsonCount(sessionKeyDownDelta)
    evidence["accessibilityTrusted"] = .bool(accessibilityTrusted)

    var payload: [String: JSONValue] = [:]
    payload["success"] = .bool(postedKeyDowns > 0)
    payload["outcome"] = .string(diagnosis.outcome.rawValue)
    payload["dispatched"] = .bool(diagnosis.outcome != .attempted)
    payload["verified"] = .bool(diagnosis.outcome == .verified)
    payload["note"] = .string(diagnosis.note)
    payload["warnings"] = .array(diagnosis.warnings.map(JSONValue.string))
    payload["keysRequested"] = jsonCount(requestedKeyDowns)
    payload["keysPosted"] = jsonCount(postedKeyDowns)
    payload["evidence"] = .object(evidence)
    payload["target"] = target.json

    for (key, value) in extra {
        payload[key] = value
    }
    return .object(payload)
}
