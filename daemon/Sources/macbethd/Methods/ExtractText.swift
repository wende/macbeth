import AppKit
import Foundation
import ScreenCaptureKit
import CoreGraphics
import Vision
import GlowProtocol

func registerExtractText(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable,
    glow: GlowIndicator
) {
    Task {
        await dispatcher.register(method: "extract_text") { params in
            guard let obj = params?.objectValue else {
                throw RPCError.invalidParams("Missing params")
            }

            let image: CGImage

            if let base64 = obj["data"]?.stringValue {
                guard let data = Data(base64Encoded: base64),
                      let provider = CGDataProvider(data: data as CFData),
                      let img = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                    throw RPCError.invalidParams("Invalid base64 PNG data")
                }
                image = img
            } else if let appHandle = obj["appHandle"]?.stringValue {
                guard let conn = await appManager.get(appHandle) else {
                    throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
                }

                let content: SCShareableContent
                do {
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                } catch {
                    throw RPCError.permissionDenied("Screen Recording permission required")
                }

                let appWindows = content.windows.filter { $0.owningApplication?.processID == conn.pid }
                guard let targetWindow = appWindows.first else {
                    throw RPCError.elementNotFound("No visible windows for app")
                }

                let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
                let config = SCStreamConfiguration()
                // extract_text is the fallback bridge for AX-opaque apps (Unity,
                // Electron IDEs), where the targets are small panel labels. Capture
                // at the window's actual native pixel resolution so Vision has the
                // most detail to work with. `pointPixelScale` is the backing scale
                // factor of the display the window is on (2 on Retina, 1 on a
                // standard external monitor); hardcoding 2x renders the window into
                // only the top-left quarter of an oversized buffer on 1x displays.
                let pixelScale = CGFloat(filter.pointPixelScale)
                config.width = max(1, Int((filter.contentRect.width * pixelScale).rounded()))
                config.height = max(1, Int((filter.contentRect.height * pixelScale).rounded()))
                config.showsCursor = false

                var captured: CGImage
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
                    if captureAnimation != nil {
                        try? await Task.sleep(for: .seconds(glowCapturePresentationDuration))
                    }
                    captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    await glow.captureFinished(id: captureAnimation, success: true)
                } catch {
                    await glow.captureFinished(id: captureAnimation, success: false)
                    throw RPCError.actionFailed("Screenshot capture failed: \(error.localizedDescription)")
                }

                if let regionObj = obj["region"]?.objectValue {
                    let scale = Double(pixelScale)
                    let rx = (regionObj["x"]?.numberValue ?? 0) * scale
                    let ry = (regionObj["y"]?.numberValue ?? 0) * scale
                    let rw = (regionObj["width"]?.numberValue ?? Double(captured.width)) * scale
                    let rh = (regionObj["height"]?.numberValue ?? Double(captured.height)) * scale
                    guard let cropped = captured.cropping(to: CGRect(x: rx, y: ry, width: rw, height: rh)) else {
                        throw RPCError.actionFailed("Region crop failed")
                    }
                    captured = cropped
                }

                image = captured
            } else {
                throw RPCError.invalidParams("Provide 'data' (base64 PNG) or 'appHandle'")
            }

            let items = try await recognizeText(in: image)

            let jsonItems: [JSONValue] = items.map { item in
                let bbox: JSONValue = .object([
                    "x": .number(item.bbox.origin.x),
                    "y": .number(item.bbox.origin.y),
                    "w": .number(item.bbox.size.width),
                    "h": .number(item.bbox.size.height),
                ])
                return .object([
                    "text": .string(item.text),
                    "confidence": .number(Double(item.confidence)),
                    "bbox": bbox,
                ])
            }
            return .object(["items": .array(jsonItems)])
        }
    }
}

struct TextItem {
    let text: String
    let confidence: Float
    let bbox: CGRect
}

func recognizeText(in image: CGImage) async throws -> [TextItem] {
    // Vision rejects images whose dimensions are not both greater than two.
    // Such an image cannot contain useful text, so return the documented empty
    // OCR result instead of asking Vision to fail it.
    guard image.width > 2, image.height > 2 else { return [] }

    // VNImageRequestHandler.perform is synchronous. A completion-handler request
    // wrapped in a checked continuation is unsafe here: on some Vision failures,
    // perform both invokes the completion handler and throws, which resumes the
    // continuation twice and crashes the entire daemon.
    let request = VNRecognizeTextRequest()
    // This is a fallback path for apps AX cannot read, so favor accuracy: use
    // Vision's accurate recognizer with language correction.
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        throw RPCError.actionFailed("OCR failed: \(error.localizedDescription)")
    }

    guard let observations = request.results else { return [] }
    let imageWidth = Double(image.width)
    let imageHeight = Double(image.height)

    return observations.compactMap { obs in
        guard let candidate = obs.topCandidates(1).first else { return nil }
        let box = obs.boundingBox
        let bx = box.origin.x * imageWidth
        let by = (1 - box.origin.y - box.height) * imageHeight
        let bw = box.width * imageWidth
        let bh = box.height * imageHeight
        let rect = CGRect(x: bx, y: by, width: bw, height: bh)
        return TextItem(text: candidate.string, confidence: candidate.confidence, bbox: rect)
    }
}
