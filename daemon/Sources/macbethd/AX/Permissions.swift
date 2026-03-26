import ApplicationServices
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
