import AppKit
import QuartzCore
import Testing
@testable import GlowProtocol
@testable import macbeth_glow

@MainActor
private final class FakeNavigationOverlayWindow: NavigationOverlayWindow {
    private(set) var targetFrame: CGRect
    private(set) var orderFrontCount = 0
    private(set) var orderOutCount = 0
    private(set) var showCount = 0
    private(set) var hideCount = 0

    init(targetFrame: CGRect) {
        self.targetFrame = targetFrame
    }

    func move(to frame: CGRect) {
        targetFrame = frame
    }

    func orderFrontRegardless() {
        orderFrontCount += 1
    }

    func orderOut(_ sender: Any?) {
        orderOutCount += 1
    }

    func showOutline(reduceMotion: Bool) -> Bool {
        showCount += 1
        return showCount == 1
    }

    func hideOutline(completion: @escaping () -> Void) {
        hideCount += 1
        completion()
    }
}

@MainActor
private func fakeOverlayController(
    debounceMs: Int = 400,
    frontmostPid: pid_t? = 42
) -> OverlayController {
    OverlayController(
        rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97),
        debounceMs: debounceMs,
        navigationWindowFactory: { frame, _ in
            FakeNavigationOverlayWindow(targetFrame: frame)
        },
        frontmostPidProvider: { frontmostPid }
    )
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

    window.captureView.start(reduceMotion: false)
    let scanLayer = try #require(window.captureView.layer?.sublayers?.last)
    let scan = try #require(
        scanLayer.animation(forKey: "capture.scan") as? CABasicAnimation
    )
    #expect(abs(scan.duration - glowCaptureScanDuration) < 0.001)
    #expect((scan.fromValue as? CGFloat) == window.captureView.bounds.maxY - 18)
    #expect((scan.toValue as? CGFloat) == 18)
    #expect(scan.repeatCount == 0)
    #expect(scan.fillMode == .forwards)
    #expect(scan.isRemovedOnCompletion == false)

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
    #expect(innerGlow.animation(forKey: "navigation.breathing") == nil)

    // Another focus while fade-in is still running must be a complete no-op.
    let revealedAgain = window.outlineView.show(reduceMotion: false)
    #expect(revealedAgain == false)
    #expect(window.outlineView.layer?.animation(forKey: "navigation.fade") === fade)

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
@Test func navigationControllerKeepsIndependentIdempotentWindowOutlines() throws {
    let controller = fakeOverlayController()
    let firstID = "pid:42:window:1"
    let secondID = "pid:42:window:2"
    let firstRect = GlowCaptureRect(x: 100, y: 100, width: 500, height: 400)
    let secondRect = GlowCaptureRect(x: 650, y: 100, width: 500, height: 400)

    controller.handle(.windowFocused(id: firstID, rect: firstRect))
    controller.handle(.windowFocused(id: secondID, rect: secondRect))
    #expect(controller.navigationOverlayCount == 2)

    let firstWindow = try #require(
        controller.navigationOutlineWindow(for: firstID) as? FakeNavigationOverlayWindow
    )
    controller.handle(.windowFocused(id: firstID, rect: firstRect))

    #expect(controller.navigationOverlayCount == 2)
    #expect(controller.navigationOutlineWindow(for: firstID) === firstWindow)
    #expect(firstWindow.orderFrontCount == 2)
    #expect(firstWindow.showCount == 2)
}

@MainActor
@Test func standaloneWindowFocusGetsItsOwnTimerDuringAnotherOperationsHold() {
    let controller = fakeOverlayController()
    let controlledID = "pid:42:window:1"
    let inspectedID = "pid:42:window:2"

    controller.handle(.activate())
    controller.handle(.windowFocused(
        id: controlledID,
        rect: GlowCaptureRect(x: 100, y: 100, width: 500, height: 400)
    ))
    controller.handle(.deactivate)
    controller.handle(.windowFocused(
        id: inspectedID,
        rect: GlowCaptureRect(x: 650, y: 100, width: 500, height: 400)
    ))

    #expect(controller.navigationFadeIsScheduled(for: controlledID))
    #expect(controller.navigationFadeIsScheduled(for: inspectedID))
}

@MainActor
@Test func newActivityCancelsPendingNavigationFadeUntilActivityEnds() throws {
    let controller = fakeOverlayController(frontmostPid: 42)
    let id = "pid:42:window:1"
    let rect = GlowCaptureRect(x: 100, y: 100, width: 500, height: 400)

    controller.handle(.activate())
    controller.handle(.windowFocused(id: id, rect: rect))
    let originalWindow = try #require(controller.navigationOutlineWindow(for: id))
    controller.handle(.deactivate)
    #expect(controller.navigationFadeIsScheduled(for: id))

    // The next operation starts before it has finished resolving the same
    // window. Its activation must hold the existing outline in place — but only
    // when that window still belongs to the frontmost app.
    controller.handle(.activate())
    #expect(!controller.navigationFadeIsScheduled(for: id))
    #expect(controller.navigationOutlineWindow(for: id) === originalWindow)

    controller.handle(.deactivate)
    #expect(controller.navigationFadeIsScheduled(for: id))
}

@MainActor
@Test func activateDoesNotRearmOutlineForBackgroundApp() throws {
    // Frontmost app is pid 7; the controlled window belongs to pid 42.
    let controller = fakeOverlayController(frontmostPid: 7)
    let id = "pid:42:window:1"
    let rect = GlowCaptureRect(x: 100, y: 100, width: 500, height: 400)

    controller.handle(.activate())
    controller.handle(.windowFocused(id: id, rect: rect))
    controller.handle(.deactivate)
    #expect(controller.navigationFadeIsScheduled(for: id))

    // Bare activate (MCP begin_activity) while another app is frontmost must not
    // re-arm the fading outline — that is the misleading background chrome bug.
    controller.handle(.activate())
    #expect(controller.navigationFadeIsScheduled(for: id))
}

@MainActor
@Test func backgroundingFrontmostAppDismissesItsOutline() throws {
    var frontmostPid: pid_t? = 42
    let controller = OverlayController(
        rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97),
        debounceMs: 400,
        navigationWindowFactory: { frame, _ in
            FakeNavigationOverlayWindow(targetFrame: frame)
        },
        frontmostPidProvider: { frontmostPid }
    )
    let id = "pid:42:window:1"
    let rect = GlowCaptureRect(x: 100, y: 100, width: 500, height: 400)

    controller.handle(.activate())
    controller.handle(.windowFocused(id: id, rect: rect))
    #expect(controller.navigationOverlayCount == 1)
    let window = try #require(
        controller.navigationOutlineWindow(for: id) as? FakeNavigationOverlayWindow
    )

    // Another app becomes frontmost (user switch, test harness sendToBackground, …).
    frontmostPid = 7
    controller.reconcileOutlinesWithFrontmostApp()

    #expect(controller.navigationOverlayCount == 0)
    #expect(window.hideCount == 1)
    #expect(window.orderOutCount == 1)
}

@Test func subPointWindowFrameChangesReuseTheSameOutline() {
    let original = CGRect(x: 100, y: 200, width: 800, height: 500)
    let jittered = CGRect(x: 100.4, y: 199.6, width: 800.5, height: 499.5)
    let moved = CGRect(x: 104, y: 200, width: 800, height: 500)
    #expect(approximatelyEqualWindowFrames(original, jittered))
    #expect(!approximatelyEqualWindowFrames(original, moved))
}

@MainActor
@Test func syntheticPointerIsClickThroughAndRecordingVisible() throws {
    let cursorScale: CGFloat = 0.3535533906
    let cursorSize = 128 * cursorScale
    let source = GlowPointerPoint(x: 100, y: 200)
    let converted = appKitPointerPoint(source, primaryDisplayTop: 1_000)
    #expect(converted == CGPoint(x: 100, y: 800))
    let initial = initialPointerPoint(near: converted, screens: [])
    #expect(abs(initial.x - (100 - 96 * cursorScale)) < 0.001)
    #expect(abs(initial.y - (800 + 78 * cursorScale)) < 0.001)
    #expect(initial != converted)

    let window = PointerOverlayWindow(
        startPoint: converted,
        rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97)
    )
    // AppKit rounds fractional point bounds to the display's pixel grid.
    #expect(abs(window.frame.width - cursorSize) < 1.0)
    #expect(abs(window.frame.height - cursorSize) < 1.0)
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
    let cursorScale: CGFloat = 0.3535533906
    let cursorHotspot = CGPoint(x: 18 * cursorScale, y: 114.5 * cursorScale)
    let window = PointerOverlayWindow(
        startPoint: CGPoint(x: 100, y: 700),
        rgba: GlowRGBA(red: 0.66, green: 0.33, blue: 0.97)
    )
    let destination = CGPoint(x: 520, y: 360)
    window.move(to: destination, action: .click, reduceMotion: false)

    try await Task.sleep(for: .milliseconds(550))
    #expect(window.targetPoint == destination)
    #expect(abs(window.frame.origin.x - (destination.x - cursorHotspot.x)) < 1.0)
    #expect(abs(window.frame.origin.y - (destination.y - cursorHotspot.y)) < 1.0)
}
