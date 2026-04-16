import AppKit
import Foundation
import ScreenCaptureKit
import CoreGraphics
import Vision

func registerExtractText(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable
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
                config.width = Int(targetWindow.frame.width) * 2
                config.height = Int(targetWindow.frame.height) * 2
                config.showsCursor = false

                var captured: CGImage
                do {
                    captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } catch {
                    throw RPCError.actionFailed("Screenshot capture failed: \(error.localizedDescription)")
                }

                if let regionObj = obj["region"]?.objectValue {
                    let scale = Double(config.width) / targetWindow.frame.width
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

private struct TextItem {
    let text: String
    let confidence: Float
    let bbox: CGRect
}

private func recognizeText(in image: CGImage) async throws -> [TextItem] {
    try await withCheckedThrowingContinuation { continuation in
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                continuation.resume(throwing: RPCError.actionFailed("OCR failed: \(error.localizedDescription)"))
                return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                continuation.resume(returning: [])
                return
            }

            let imageWidth = Double(image.width)
            let imageHeight = Double(image.height)

            let items: [TextItem] = observations.compactMap { obs in
                guard let candidate = obs.topCandidates(1).first else { return nil }
                let box = obs.boundingBox
                let bx = box.origin.x * imageWidth
                let by = (1 - box.origin.y - box.height) * imageHeight
                let bw = box.width * imageWidth
                let bh = box.height * imageHeight
                let rect = CGRect(x: bx, y: by, width: bw, height: bh)
                return TextItem(text: candidate.string, confidence: candidate.confidence, bbox: rect)
            }

            continuation.resume(returning: items)
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            continuation.resume(throwing: RPCError.actionFailed("OCR failed: \(error.localizedDescription)"))
        }
    }
}
