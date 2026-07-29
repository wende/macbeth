import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import GlowProtocol

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

            let selectedWindowID = obj["windowId"]?.intValue
            let content: SCShareableContent
            do {
                // Preserve legacy selection for callers that omit windowId.
                // Explicit selection needs the all-Spaces catalog returned by
                // list_windows and never activates or moves the target window.
                content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: selectedWindowID == nil
                )
            } catch {
                throw screenCaptureContentError(error)
            }

            let targetWindow: SCWindow
            if let selectedWindowID {
                targetWindow = try resolveSelectedWindow(
                    in: content, ownedBy: conn.pid, windowID: selectedWindowID)
            } else {
                targetWindow = try resolveDefaultWindow(
                    in: content, ownedBy: conn.pid)
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
            // Outline/activity stay frontmost-only (honest chrome). The capture
            // scan/snap always runs so demos and external recordings still show
            // which window is being captured when a recorder holds frontmost.
            let ownerPID = targetWindow.owningApplication?.processID ?? conn.pid
            let isFrontmost = ElementGeometry.isFrontmostWindow(
                pid: ownerPID,
                windowNumber: Int(targetWindow.windowID)
            )
            if isFrontmost { await glow.activityStarted() }
            defer {
                if isFrontmost { Task { await glow.activityEnded() } }
            }
            let windowID = ElementGeometry.windowIdentity(
                pid: ownerPID, windowNumber: Int(targetWindow.windowID)
            )
            let captureAnimation = await glow.captureStarted(
                windowID: windowID,
                frame: targetWindow.frame,
                presentOutline: isFrontmost
            )
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
