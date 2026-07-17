import CoreGraphics
import Foundation

/// Prints JSON `{ "outlines": N, "windows": [...] }` for on-screen `macbeth-glow`
/// navigation outlines (full-window frames). Excludes the ~46pt pointer overlay.
///
/// Used by the MCP foregrounding suite to assert that backgrounded actions do
/// not draw a target outline.
///
/// Enumerates all windows (not only the default on-screen set) and filters by
/// `kCGWindowIsOnscreen` so briefly re-ordered assistive overlays are not missed.
let opts = CGWindowListOption(arrayLiteral: .optionAll, .excludeDesktopElements)
guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print(#"{"outlines":0,"windows":[]}"#)
    exit(0)
}

var windows: [[String: Any]] = []
for w in info {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner == "macbeth-glow" else { continue }

    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    guard onscreen else { continue }

    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
    // Pointer overlay is ~46×46; outline tracks the target app window (+ padding).
    // Capture overlays are also full-window sized and count as a visible chrome.
    guard width >= 80, height >= 80 else { continue }

    let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    // Fully transparent shells should not count as a visible outline.
    guard alpha > 0.02 else { continue }

    windows.append([
        "owner": owner,
        "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0,
        "layer": w[kCGWindowLayer as String] as? Int ?? 0,
        "alpha": alpha,
        "width": width,
        "height": height,
        "x": (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
        "y": (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
    ])
}

let payload: [String: Any] = ["outlines": windows.count, "windows": windows]
let data = try! JSONSerialization.data(withJSONObject: payload)
FileHandle.standardOutput.write(data)
print()
