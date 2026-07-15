import AppKit
import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO

/// Check if Screen Recording permission is likely granted.
/// There's no direct API like AXIsProcessTrusted, so we attempt a lightweight capture.
private func hasScreenRecordingPermission() async -> Bool {
    do {
        let _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return true
    } catch {
        return false
    }
}

/// Open System Settings to the Screen Recording privacy pane.
private func openScreenRecordingSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
        NSWorkspace.shared.open(url)
    }
}

/// Register the screenshot RPC method.
func registerScreenshot(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager
) {
    Task {
        await dispatcher.register(method: "screenshot") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'appHandle'")
            }

            guard let conn = await appManager.get(appHandle) else {
                throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
            }

            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                // Permission denied — open settings and tell the user
                openScreenRecordingSettings()
                throw RPCError.permissionDenied(
                    "Screen Recording permission required. Opening System Settings → Privacy & Security → Screen Recording. Grant access to macbethd (or your terminal app), then retry.")
            }

            let appWindows = content.windows.filter { $0.owningApplication?.processID == conn.pid }

            guard let targetWindow = appWindows.first else {
                throw RPCError.elementNotFound("No visible windows for app (PID: \(conn.pid))")
            }

            // Capture is scoped to a single window owned by the *target* app.
            // The glow overlay lives in a separate process (macbeth-glow) and its
            // windows also set sharingType = .none, so the indicator can never
            // appear in a macbeth screenshot.
            let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
            let config = SCStreamConfiguration()
            config.width = Int(targetWindow.frame.width) * 2
            config.height = Int(targetWindow.frame.height) * 2
            config.showsCursor = false

            var image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                throw RPCError.actionFailed("Screenshot capture failed: \(error.localizedDescription)")
            }

            if let regionObj = obj["region"]?.objectValue {
                let scale = Double(config.width) / targetWindow.frame.width
                let rx = (regionObj["x"]?.numberValue ?? 0) * scale
                let ry = (regionObj["y"]?.numberValue ?? 0) * scale
                let rw = (regionObj["width"]?.numberValue ?? Double(image.width)) * scale
                let rh = (regionObj["height"]?.numberValue ?? Double(image.height)) * scale
                let cropRect = CGRect(x: rx, y: ry, width: rw, height: rh)
                guard let cropped = image.cropping(to: cropRect) else {
                    throw RPCError.actionFailed("Region crop failed — check coordinates")
                }
                image = cropped
            }

            let mutableData = CFDataCreateMutable(nil, 0)!
            guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
                throw RPCError.actionFailed("Failed to create PNG encoder")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw RPCError.actionFailed("Failed to encode PNG")
            }

            let pngData = mutableData as Data
            let base64 = pngData.base64EncodedString()

            return .object([
                "data": .string(base64),
                "width": .number(Double(image.width)),
                "height": .number(Double(image.height)),
                "format": .string("png"),
            ])
        }
    }
}
