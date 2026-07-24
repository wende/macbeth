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

@Test func imageForOCRLeavesSmallImagesUnchanged() {
    let image = makeSolidImage(width: 400, height: 300)
    let result = imageForOCR(image, maxDimension: 1600)
    #expect(result.width == 400)
    #expect(result.height == 300)
}

@Test func imageForOCRCapsLongestSide() {
    let image = makeSolidImage(width: 3200, height: 1800)
    let result = imageForOCR(image, maxDimension: 1600)
    #expect(result.width == 1600)
    #expect(result.height == 900)
}

@Test func imageForOCRCapsTallImagesByHeight() {
    let image = makeSolidImage(width: 900, height: 2400)
    let result = imageForOCR(image, maxDimension: 1600)
    #expect(result.width == 600)
    #expect(result.height == 1600)
}

private func makeSolidImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
