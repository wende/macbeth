import CoreGraphics
import Testing
@testable import macbethd

@Test func tinyImageReturnsAnEmptyOCRResultWithoutCrashing() async throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let image = context.makeImage()!

    let items = try await recognizeText(in: image)

    #expect(items.isEmpty)
}
