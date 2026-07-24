import CoreGraphics
import Foundation

/// Prints JSON for on-screen `macbeth-glow` chrome:
/// `{ "outlines": N, "captures": M, "windows": [...] }`
///
/// Window levels (see macbeth-glow overlays):
/// - navigation outline: assistiveTechHigh - 1
/// - capture scan/snap:  assistiveTechHigh
/// - pointer:            assistiveTechHigh + 1 (excluded by size)
///
/// Used by the MCP foregrounding suite: backgrounded actions must not draw a
/// target *outline*. Screenshot may still show a capture overlay.
///
/// Enumerates all windows (not only the default on-screen set) and filters by
/// `kCGWindowIsOnscreen` so briefly re-ordered assistive overlays are not missed.
let opts = CGWindowListOption(arrayLiteral: .optionAll, .excludeDesktopElements)
guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print(#"{"outlines":0,"captures":0,"windows":[]}"#)
    exit(0)
}

let captureLayer = Int(CGWindowLevelForKey(.assistiveTechHighWindow))
let outlineLayer = captureLayer - 1

var windows: [[String: Any]] = []
var outlines = 0
var captures = 0

for w in info {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    guard owner == "macbeth-glow" else { continue }

    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    guard onscreen else { continue }

    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
    // Pointer overlay is ~46×46; outline/capture track the target app window (+ padding).
    guard width >= 80, height >= 80 else { continue }

    let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    // Fully transparent shells should not count as visible chrome.
    guard alpha > 0.02 else { continue }

    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let kind: String
    if layer == captureLayer {
        kind = "capture"
        captures += 1
    } else if layer == outlineLayer {
        kind = "outline"
        outlines += 1
    } else {
        // Unknown large glow window — count as outline so honesty tests stay strict.
        kind = "outline"
        outlines += 1
    }

    windows.append([
        "owner": owner,
        "kind": kind,
        "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0,
        "layer": layer,
        "alpha": alpha,
        "width": width,
        "height": height,
        "x": (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
        "y": (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
    ])
}

let payload: [String: Any] = [
    "outlines": outlines,
    "captures": captures,
    "windows": windows,
]
let data = try! JSONSerialization.data(withJSONObject: payload)
FileHandle.standardOutput.write(data)
print()
