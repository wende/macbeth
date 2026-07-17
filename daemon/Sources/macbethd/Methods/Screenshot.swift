import AppKit
import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import GlowProtocol

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
    appManager: AppConnectionManager,
    glow: GlowIndicator
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
            // The target-window filter only includes content owned by the target
            // app, and the focus/capture overlays belong to the separate
            // macbeth-glow process, so they cannot appear in this image (even
            // though the overlays are sharingType = .readOnly for recordings).
            let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
            let config = SCStreamConfiguration()
            // Size the capture buffer to the window's *actual* native pixel
            // dimensions. `contentRect` is in points and `pointPixelScale` is the
            // backing scale factor of the display the window is on (2 on Retina,
            // 1 on a standard external monitor, etc.). Hardcoding a 2x factor
            // assumes every display is Retina — on a 1x display the window renders
            // into only the top-left quarter of an oversized buffer, leaving the
            // rest blank (the "4x too big with whitespace" bug).
            let pixelScale = CGFloat(filter.pointPixelScale)
            config.width = max(1, Int((filter.contentRect.width * pixelScale).rounded()))
            config.height = max(1, Int((filter.contentRect.height * pixelScale).rounded()))
            config.showsCursor = false

            var image: CGImage
            let showGlow = ElementGeometry.isFrontmostWindow(
                pid: conn.pid,
                windowNumber: Int(targetWindow.windowID)
            )
            if showGlow { await glow.activityStarted() }
            defer {
                if showGlow { Task { await glow.activityEnded() } }
            }
            let windowID = ElementGeometry.windowIdentity(
                pid: conn.pid, windowNumber: Int(targetWindow.windowID)
            )
            let captureAnimation = showGlow
                ? await glow.captureStarted(windowID: windowID, frame: targetWindow.frame)
                : nil
            do {
                // Keep the scanning phase alive for one complete top-to-bottom
                // pass. The helper is excluded by the desktop-independent
                // target filter, so this presentation delay cannot affect the
                // captured pixels.
                if captureAnimation != nil {
                    try? await Task.sleep(for: .seconds(glowCapturePresentationDuration))
                }
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                await glow.captureFinished(id: captureAnimation, success: true)
            } catch {
                await glow.captureFinished(id: captureAnimation, success: false)
                throw RPCError.actionFailed("Screenshot capture failed: \(error.localizedDescription)")
            }

            if let regionObj = obj["region"]?.objectValue {
                // Region coordinates arrive in window points; convert to the
                // captured image's pixels using the same native scale factor.
                let scale = Double(pixelScale)
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
