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
@Test func glowUsesGentleFadeDurations() throws {
    let view = GlowView(rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97))

    view.fadeIn(reduceMotion: true)
    let fadeIn = try #require(view.layer?.animation(forKey: "glow.fade") as? CABasicAnimation)
    #expect(abs(fadeIn.duration - 0.2) < 0.001)

    view.fadeOut {}
    let fadeOut = try #require(view.layer?.animation(forKey: "glow.fade") as? CABasicAnimation)
    #expect(abs(fadeOut.duration - 0.7) < 0.001)

    view.fadeIn(reduceMotion: false)
    let breathing = try #require(
        view.layer?.sublayers?.first?.animation(forKey: "glow.breathing") as? CABasicAnimation
    )
    #expect(abs(breathing.duration - 1.0) < 0.001)
}

@MainActor
@Test func captureOverlayTracksWindowWithoutStealingInput() throws {
    let captureRect = GlowCaptureRect(x: 100, y: 200, width: 800, height: 500)
    let targetFrame = appKitCaptureFrame(captureRect, primaryDisplayTop: 1_000)
    #expect(targetFrame == CGRect(x: 100, y: 300, width: 800, height: 500))

    let window = CaptureOverlayWindow(
        targetFrame: targetFrame,
        rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97)
    )
    #expect(window.frame == targetFrame.insetBy(dx: -18, dy: -18))
    #expect(window.ignoresMouseEvents)
    #expect(window.canBecomeKey == false)
    #expect(window.canBecomeMain == false)
    #expect(window.sharingType == .readOnly)

    window.captureView.start(reduceMotion: true)
    let fade = try #require(
        window.captureView.layer?.animation(forKey: "capture.rootFade") as? CABasicAnimation
    )
    #expect(abs(fade.duration - 0.2) < 0.001)

    window.captureView.finish(success: true) {}
    let washLayer = try #require(window.captureView.layer?.sublayers?.first)
    let snap = try #require(
        washLayer.animation(forKey: "capture.snap") as? CAKeyframeAnimation
    )
    #expect(abs(snap.duration - 0.58) < 0.001)
    let dissolve = try #require(
        window.captureView.layer?.animation(forKey: "capture.rootFade") as? CABasicAnimation
    )
    #expect(abs(dissolve.duration - 0.66) < 0.001)
}

@MainActor
@Test func navigationOutlineTracksCurrentWindowWithoutStealingInput() throws {
    let targetFrame = CGRect(x: 120, y: 240, width: 700, height: 460)
    let window = NavigationOutlineWindow(
        targetFrame: targetFrame,
        rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97)
    )

    #expect(window.frame == targetFrame.insetBy(dx: -12, dy: -12))
    #expect(window.ignoresMouseEvents)
    #expect(window.canBecomeKey == false)
    #expect(window.canBecomeMain == false)
    #expect(window.sharingType == .readOnly)

    window.outlineView.show(reduceMotion: false)
    let fade = try #require(
        window.outlineView.layer?.animation(forKey: "navigation.fade") as? CABasicAnimation
    )
    #expect(abs(fade.duration - 0.28) < 0.001)

    let innerGlow = try #require(window.outlineView.layer?.sublayers?.first)
    let gradients = try #require(innerGlow.sublayers as? [CAGradientLayer])
    #expect(gradients.count == 4)
    let innerBreathing = try #require(
        innerGlow.animation(forKey: "navigation.breathing") as? CABasicAnimation
    )
    #expect(abs(innerBreathing.duration - 1.2) < 0.001)

    let movedFrame = targetFrame.offsetBy(dx: 30, dy: -20)
    window.move(to: movedFrame)
    #expect(window.targetFrame == movedFrame)
    #expect(window.frame == movedFrame.insetBy(dx: -12, dy: -12))

    window.outlineView.hide {}
    let fadeOut = try #require(
        window.outlineView.layer?.animation(forKey: "navigation.fade") as? CABasicAnimation
    )
    #expect(abs(fadeOut.duration - 0.7) < 0.001)
}

@MainActor
@Test func syntheticPointerIsClickThroughAndRecordingVisible() throws {
    let source = GlowPointerPoint(x: 100, y: 200)
    let converted = appKitPointerPoint(source, primaryDisplayTop: 1_000)
    #expect(converted == CGPoint(x: 100, y: 800))
    let initial = initialPointerPoint(near: converted, screens: [])
    #expect(abs(initial.x - (100 - 52 * 0.7071067812)) < 0.001)
    #expect(abs(initial.y - (800 + 42 * 0.7071067812)) < 0.001)
    #expect(initial != converted)

    let window = PointerOverlayWindow(
        startPoint: converted,
        rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97)
    )
    // AppKit rounds fractional point bounds to the display's pixel grid.
    #expect(abs(window.frame.width - 64 * 0.7071067812) < 1.0)
    #expect(abs(window.frame.height - 64 * 0.7071067812) < 1.0)
    #expect(window.ignoresMouseEvents)
    #expect(window.canBecomeKey == false)
    #expect(window.canBecomeMain == false)
    #expect(window.sharingType == .readOnly)

    window.pointerView.show(reduceMotion: false)
    let fade = try #require(
        window.pointerView.layer?.animation(forKey: "pointer.fade") as? CABasicAnimation
    )
    #expect(abs(fade.duration - 0.18) < 0.001)

    window.pointerView.hide {}
    let fadeOut = try #require(
        window.pointerView.layer?.animation(forKey: "pointer.fade") as? CABasicAnimation
    )
    #expect(abs(fadeOut.duration - 0.7) < 0.001)
}

@MainActor
@Test func syntheticPointerTravelsBetweenDistinctTargets() async throws {
    let window = PointerOverlayWindow(
        startPoint: CGPoint(x: 100, y: 700),
        rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97)
    )
    let destination = CGPoint(x: 520, y: 360)
    window.move(to: destination, action: .click, reduceMotion: false)

    try await Task.sleep(for: .milliseconds(550))
    #expect(window.targetPoint == destination)
    #expect(abs(window.frame.origin.x - (destination.x - 16 * 0.7071067812)) < 1.0)
    #expect(abs(window.frame.origin.y - (destination.y - 52 * 0.7071067812)) < 1.0)
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
