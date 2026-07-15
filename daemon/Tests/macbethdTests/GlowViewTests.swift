import AppKit
import QuartzCore
import Testing
@testable import GlowProtocol
@testable import macbeth_glow

@MainActor
@Test func glowGradientsStartAtEachEdgeAndFadeInward() throws {
    let view = GlowView(rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97))
    view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    view.layoutSubtreeIfNeeded()

    let container = try #require(view.layer?.sublayers?.first)
    let gradients = try #require(container.sublayers as? [CAGradientLayer])
    #expect(gradients.count == 4)

    let top = gradients[0]
    #expect(top.frame == CGRect(x: 0, y: 556, width: 800, height: 44))
    #expect(top.startPoint == CGPoint(x: 0.5, y: 1))
    #expect(top.endPoint == CGPoint(x: 0.5, y: 0))

    let bottom = gradients[1]
    #expect(bottom.frame == CGRect(x: 0, y: 0, width: 800, height: 44))
    #expect(bottom.startPoint == CGPoint(x: 0.5, y: 0))
    #expect(bottom.endPoint == CGPoint(x: 0.5, y: 1))

    let left = gradients[2]
    #expect(left.frame == CGRect(x: 0, y: 0, width: 44, height: 600))
    #expect(left.startPoint == CGPoint(x: 0, y: 0.5))
    #expect(left.endPoint == CGPoint(x: 1, y: 0.5))

    let right = gradients[3]
    #expect(right.frame == CGRect(x: 756, y: 0, width: 44, height: 600))
    #expect(right.startPoint == CGPoint(x: 1, y: 0.5))
    #expect(right.endPoint == CGPoint(x: 0, y: 0.5))

    for gradient in gradients {
        #expect(gradient.colors?.count == 6)
        #expect(gradient.locations == [0, 0.08, 0.24, 0.5, 0.75, 1])
    }
}

@MainActor
@Test func overlayRemainsClickThroughAndNonCapturable() throws {
    let screen = try #require(NSScreen.main)
    let window = OverlayWindow(
        screen: screen,
        rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97)
    )

    #expect(window.ignoresMouseEvents)
    #expect(window.sharingType == .none)
    #expect(window.canBecomeKey == false)
    #expect(window.canBecomeMain == false)
}

@MainActor
@Test func renderedGradientFallsOffTowardScreenCenter() throws {
    let width = 200
    let height = 150
    let view = GlowView(rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97))
    view.frame = CGRect(x: 0, y: 0, width: width, height: height)
    view.layoutSubtreeIfNeeded()
    view.layer?.opacity = 1

    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    view.layer?.render(in: context)

    let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
    func alpha(x: Int, y: Int) -> UInt8 {
        pixels[y * context.bytesPerRow + x * 4 + 3]
    }

    let edgeAlpha = alpha(x: width / 2, y: 0)
    let middleAlpha = alpha(x: width / 2, y: 22)
    let innerAlpha = alpha(x: width / 2, y: 45)
    #expect(edgeAlpha > middleAlpha)
    #expect(middleAlpha > innerAlpha)
    #expect(innerAlpha <= 1)
}
