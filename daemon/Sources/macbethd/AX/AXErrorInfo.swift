@preconcurrency import ApplicationServices
import Foundation

/// A raw `AXError` translated into something a caller can act on.
///
/// Accessibility failures surface as bare integers (`-25204`, `-25211`, …) that mean
/// nothing without the header they came from. Every place macbeth reports an AX failure
/// goes through this type so the code, a plain-language explanation, and a likely next
/// step travel together.
struct AXErrorInfo: Sendable, Equatable {
    let code: Int32
    /// Stable snake_case identifier for the `AXError` case, e.g. `cannot_complete`.
    let name: String
    /// What the code means for the caller.
    let explanation: String
    /// The most likely way to make progress.
    let nextAction: String

    /// One-line rendering used in RPC error messages.
    var summary: String {
        "AX error \(code) (\(name)): \(explanation) Next: \(nextAction)"
    }

    /// Structured form attached to JSON-RPC error `data` and to `list_apps` entries.
    var json: JSONValue {
        .object([
            "axCode": .number(Double(code)),
            "axError": .string(name),
            "explanation": .string(explanation),
            "nextAction": .string(nextAction),
        ])
    }
}

private let screenshotFallback =
    "Fall back to screenshot + extract_text for reading, and select_menu_item or "
    + "run_applescript for driving the app."

/// Explain an `AXError` returned by the Accessibility API.
func axErrorInfo(_ error: AXError) -> AXErrorInfo {
    axErrorInfo(code: error.rawValue)
}

/// Explain a raw AX error code. Codes outside the documented range still get a usable
/// entry so an unfamiliar value never reaches a caller uninterpreted.
func axErrorInfo(code: Int32) -> AXErrorInfo {
    switch code {
    case 0:
        return AXErrorInfo(
            code: code,
            name: "success",
            explanation: "The accessibility request succeeded.",
            nextAction: "No action needed."
        )
    case -25200:
        return AXErrorInfo(
            code: code,
            name: "failure",
            explanation: "The Accessibility API failed for an unspecified reason, usually a "
                + "transient system or app-side fault.",
            nextAction: "Retry once; if it persists, restart the target app."
        )
    case -25201:
        return AXErrorInfo(
            code: code,
            name: "illegal_argument",
            explanation: "The Accessibility API rejected one of the arguments macbeth sent.",
            nextAction: "Re-resolve the element with query_tree and retry; report this if it repeats."
        )
    case -25202:
        return AXErrorInfo(
            code: code,
            name: "invalid_ui_element",
            explanation: "The element or application reference is stale — the app quit, or that "
                + "part of the UI was rebuilt.",
            nextAction: "Re-run connect_app or query_tree to mint fresh handles, then retry."
        )
    case -25204:
        return AXErrorInfo(
            code: code,
            name: "cannot_complete",
            explanation: "The process did not answer the accessibility request. This is what a "
                + "process that is not an AX-capable GUI app looks like — launchers and helper "
                + "processes, apps still starting up, and apps blocked on their main thread all "
                + "fail this way.",
            nextAction: "Confirm the app has finished launching and has a real window, then retry. "
                + "If it keeps failing, this process cannot be automated through Accessibility. "
                + screenshotFallback
        )
    case -25205:
        return AXErrorInfo(
            code: code,
            name: "attribute_unsupported",
            explanation: "The element does not expose the requested accessibility attribute.",
            nextAction: "Use dump_attributes to see what the element actually exposes."
        )
    case -25206:
        return AXErrorInfo(
            code: code,
            name: "action_unsupported",
            explanation: "The element does not support the requested accessibility action.",
            nextAction: "For clicks, retry with strategy \"mouse\"; otherwise drive the app through "
                + "select_menu_item or press_key."
        )
    case -25208:
        return AXErrorInfo(
            code: code,
            name: "not_implemented",
            explanation: "The process does not implement the Accessibility API for this request. "
                + "Games, custom-rendered canvases, and some cross-platform toolkits never do.",
            nextAction: screenshotFallback
        )
    case -25211:
        return AXErrorInfo(
            code: code,
            name: "api_disabled",
            explanation: "Accessibility permission has not been granted, so macOS refuses every "
                + "accessibility request regardless of which app is targeted.",
            nextAction: "Grant Accessibility to the macbeth daemon (or your terminal) under System "
                + "Settings → Privacy & Security → Accessibility, then retry. "
                + "`npx macbeth doctor` prints the exact steps."
        )
    case -25212:
        return AXErrorInfo(
            code: code,
            name: "no_value",
            explanation: "The attribute exists but currently holds no value.",
            nextAction: "Treat the value as empty, or wait for the app to populate it with wait_for."
        )
    case -25213:
        return AXErrorInfo(
            code: code,
            name: "parameterized_attribute_unsupported",
            explanation: "The element does not support the requested parameterized attribute.",
            nextAction: "Use dump_attributes to see what the element actually exposes."
        )
    default:
        return AXErrorInfo(
            code: code,
            name: "unknown",
            explanation: "The Accessibility API returned an error code macbeth does not recognise.",
            nextAction: "Retry once; if it persists, report the code with the app name. "
                + screenshotFallback
        )
    }
}
