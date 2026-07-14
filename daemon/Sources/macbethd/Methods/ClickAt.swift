@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The scale factor `Screenshot.swift` captures at: image pixels = window points × this.
/// Keep in sync with `Screenshot.swift` (`config.width = frame.width * 2`) so that
/// `space: "screenshot"` coordinates map back to the exact pixels of that image.
let screenshotScale: Double = 2.0

/// Register the coordinate-based click RPC method.
///
/// Unlike `click`, this never needs an AX element — it's the primitive for
/// AX-opaque surfaces (Electron, `<canvas>`, games) where an agent can only
/// see a screenshot. The click is delivered via `postToPid`, so it moves
/// neither the hardware cursor nor the frontmost app.
func registerClickAt(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager
) {
    Task {
        await dispatcher.register(method: "click_at") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue,
                  let x = obj["x"]?.numberValue,
                  let y = obj["y"]?.numberValue else {
                throw RPCError.invalidParams("Missing 'appHandle', 'x', or 'y'")
            }
            let space = obj["space"]?.stringValue ?? "screenshot"
            // Delivery mechanism:
            //   "pid" (default) — postToPid, no cursor/focus takeover, but Chromium/
            //                     Electron web content ignores it (see notes below).
            //   "hid"           — post to the HID event tap; moves the real cursor and
            //                     lands on the frontmost window. Works on Electron.
            let via = obj["via"]?.stringValue ?? "pid"

            guard let conn = await appManager.get(appHandle) else {
                throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
            }

            let screenPoint: CGPoint
            switch space {
            case "screen":
                screenPoint = CGPoint(x: x, y: y)
            case "window", "screenshot":
                guard let frame = try await firstWindowFrame(pid: conn.pid) else {
                    throw RPCError.elementNotFound("No visible window for app (PID: \(conn.pid))")
                }
                // "window" coords are already in points; "screenshot" coords are
                // pixels in the 2× capture, so divide by the capture scale.
                let divisor = (space == "screenshot") ? screenshotScale : 1.0
                screenPoint = CGPoint(
                    x: frame.origin.x + x / divisor,
                    y: frame.origin.y + y / divisor
                )
            default:
                throw RPCError.invalidParams(
                    "Invalid 'space': \(space) (expected 'screenshot', 'window', or 'screen')")
            }

            switch via {
            case "pid":
                postClickEvent(at: screenPoint, toPid: conn.pid)
            case "hid":
                postClickEventHID(at: screenPoint)
            default:
                throw RPCError.invalidParams("Invalid 'via': \(via) (expected 'pid' or 'hid')")
            }

            return .object([
                "success": .bool(true),
                "screenX": .number(screenPoint.x),
                "screenY": .number(screenPoint.y),
                "via": .string(via),
            ])
        }
    }
}

/// Click at a screen point via the HID event tap (the global cursor stream).
///
/// This is a genuine screen takeover — the hardware cursor moves and the click
/// lands on whatever window is frontmost/under the point. It's the only
/// mechanism that drives Chromium/Electron web content, which ignores
/// `postToPid` mouse events. We snapshot and restore the cursor position to
/// keep the disruption to a brief flick rather than a permanent jump.
private func postClickEventHID(at point: CGPoint) {
    let saved = CGEvent(source: nil)?.location
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    usleep(80_000)
    up?.post(tap: .cghidEventTap)
    if let saved {
        usleep(30_000)
        CGWarpMouseCursorPosition(saved)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// Frame (screen points, top-left origin) of the first on-screen window of `pid`.
/// Mirrors `Screenshot.swift`'s target selection so coordinate spaces line up.
private func firstWindowFrame(pid: pid_t) async throws -> CGRect? {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let appWindows = content.windows.filter { $0.owningApplication?.processID == pid }
    return appWindows.first?.frame
}
