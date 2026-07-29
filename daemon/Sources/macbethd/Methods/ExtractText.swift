import AppKit
import Foundation
import ScreenCaptureKit
import CoreGraphics
import Vision
import GlowProtocol

/// Longest image side (pixels) fed to Vision. Full Retina windows are far larger
/// than UI OCR needs; capping keeps recognition under a few seconds.
let ocrMaxDimension = 1600

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

                let selectedWindowID = obj["windowId"]?.intValue
                let content: SCShareableContent
                do {
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

                let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
                let config = SCStreamConfiguration()
                // Capture at the window's native pixel size, then downscale for
                // Vision below. Region crops stay in native pixels so coordinates
                // match screenshots.
                let pixelScale = CGFloat(filter.pointPixelScale)
                config.width = max(1, Int((filter.contentRect.width * pixelScale).rounded()))
                config.height = max(1, Int((filter.contentRect.height * pixelScale).rounded()))
                config.showsCursor = false

                var captured: CGImage
                // OCR only needs the activity ring — the ~1s capture-scan presentation
                // delay is for screenshot aesthetics and would dominate latency here.
                let showGlow = ElementGeometry.isFrontmostWindow(
                    pid: targetWindow.owningApplication?.processID ?? conn.pid,
                    windowNumber: Int(targetWindow.windowID)
                )
                if showGlow { await glow.activityStarted() }
                defer {
                    if showGlow { Task { await glow.activityEnded() } }
                }
                do {
                    captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } catch {
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

/// Downscale `image` so its longest side is at most `maxDimension`. Returns the
/// original image when already small enough or when scaling fails.
func imageForOCR(_ image: CGImage, maxDimension: Int = ocrMaxDimension) -> CGImage {
    let longest = max(image.width, image.height)
    guard longest > maxDimension, maxDimension > 0 else { return image }

    let scale = CGFloat(maxDimension) / CGFloat(longest)
    let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

    let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return image
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
}

func recognizeText(in image: CGImage) async throws -> [TextItem] {
    // Vision rejects images whose dimensions are not both greater than two.
    // Such an image cannot contain useful text, so return the documented empty
    // OCR result instead of asking Vision to fail it.
    guard image.width > 2, image.height > 2 else { return [] }

    // Feed Vision a capped-resolution copy. Bounding boxes from Vision are
    // normalized 0…1, so we still map them into the *original* image's pixel
    // space for stable coordinates vs screenshots.
    let ocrImage = imageForOCR(image)

    // VNImageRequestHandler.perform is synchronous. A completion-handler request
    // wrapped in a checked continuation is unsafe here: on some Vision failures,
    // perform both invokes the completion handler and throws, which resumes the
    // continuation twice and crashes the entire daemon.
    let request = VNRecognizeTextRequest()
    // Prefer latency over maximum accuracy. UI labels and panel text are clear
    // enough for the fast recognizer; `.accurate` + language correction routinely
    // multi-second (and cold-start can hit tens of seconds) on full windows.
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: ocrImage, options: [:])
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
