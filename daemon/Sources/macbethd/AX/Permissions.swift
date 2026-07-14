import ApplicationServices
import CoreGraphics
import Foundation

/// Check if the process has Accessibility permissions.
/// If `prompt` is true, macOS will show the permission dialog.
func checkAccessibilityPermissions(prompt: Bool = false) -> Bool {
    // kAXTrustedCheckOptionPrompt is "AXTrustedCheckOptionPrompt" — use the string
    // directly to avoid Swift 6 strict concurrency error on the global C variable.
    let key = "AXTrustedCheckOptionPrompt" as CFString
    let options = [key: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

/// Check Screen Recording permission using CGPreflightScreenCaptureAccess.
/// Does NOT trigger the interactive permission prompt.
func checkScreenRecordingPermission() -> Bool {
    return CGPreflightScreenCaptureAccess()
}

/// Print guidance for granting Accessibility permissions.
func printPermissionGuidance() {
    let msg = """
    ⚠️  macbethd requires Accessibility permissions.

    Grant access in:
      System Settings → Privacy & Security → Accessibility

    Add the macbethd binary (or your terminal app) to the allowed list.

    If running from Terminal/iTerm, the terminal app itself needs the permission.
    """
    fputs(msg + "\n", stderr)
}

/// Run a one-shot permissions check and print a human-readable report.
/// Exits 0 if Accessibility is granted; non-zero otherwise. The
/// screen-capture permission is reported but is NOT required for the
/// AX-driven end-to-end test (only for screenshot RPC). Intended for CI.
func runPermissionsCheck() -> Never {
    let ax = checkAccessibilityPermissions(prompt: false)
    let screen = checkScreenRecordingPermission()

    let axStatus = ax ? "GRANTED" : "DENIED"
    let screenStatus = screen ? "GRANTED" : "DENIED"

    print("macbethd permission preflight")
    print("  executable:    \(ProcessInfo.processInfo.arguments[0])")
    print("  pid:           \(getpid())")
    print("  accessibility: \(axStatus)")
    print("  screen_capture: \(screenStatus)")

    if !ax {
        print("")
        print("Accessibility is required for AX queries, click, fill, and read_form.")
        print("Grant in: System Settings → Privacy & Security → Accessibility")
    }
    if !screen {
        print("")
        print("Screen Recording is required for screenshot capture (SCShareableContent).")
        print("Grant in: System Settings → Privacy & Security → Screen Recording")
    }

    // Exit 0 only if Accessibility (the gating permission for AX) is
    // granted. Screen capture being denied does not block the AX-driven
    // test — it just disables the screenshot RPC.
    if ax { exit(0) }
    exit(1)
}
