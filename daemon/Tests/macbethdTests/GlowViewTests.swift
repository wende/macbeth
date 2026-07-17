import AppKit
import QuartzCore
import Testing
@testable import GlowProtocol
@testable import macbeth_glow

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

    window.captureView.start(reduceMotion: false)
    let scanLayer = try #require(window.captureView.layer?.sublayers?.last)
    let scan = try #require(
        scanLayer.animation(forKey: "capture.scan") as? CABasicAnimation
    )
    #expect(abs(scan.duration - glowCaptureScanDuration) < 0.001)
    #expect((scan.fromValue as? CGFloat) == window.captureView.bounds.maxY - 18)
    #expect((scan.toValue as? CGFloat) == 18)

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
    #expect(abs(fadeOut.duration - glowWindowFadeDuration) < 0.001)
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
