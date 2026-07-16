import AppKit
import GlowProtocol

/// Owns the overlay windows and drives show / hide in response to daemon
/// messages. All methods run on the main thread.
@MainActor
final class OverlayController: NSObject {
    private var windows: [OverlayWindow] = []
    private var rgba: GlowRGBA
    private var tracker: GlowActivityTracker
    private var fadeOutTimer: Timer?
    private var isShowing = false
    private var captureWindows: [String: CaptureOverlayWindow] = [:]
    private var captureTimeouts: [String: Timer] = [:]
    private var navigationWindow: NavigationOutlineWindow?
    private var navigationRect: GlowCaptureRect?
    private var navigationFadeTimer: Timer?
    private var navigationGeneration = 0
    private var pointerWindow: PointerOverlayWindow?
    private var pointerGeneration = 0
    /// Invalidates completion handlers from an interrupted fade-out so they
    /// cannot order out a newly reactivated window.
    private var transitionGeneration = 0

    init(rgba: GlowRGBA, debounceMs: Int) {
        self.rgba = rgba
        self.tracker = GlowActivityTracker(debounceMs: debounceMs)
        super.init()
    }

    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func start() {
        rebuildWindows()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    // MARK: - Message handling

    func handle(_ message: GlowMessage) {
        switch message.type {
        case .activate:
            if let hex = message.color, let parsed = parseGlowColor(hex), parsed != rgba {
                rgba = parsed
                windows.forEach { $0.glowView.setColor(parsed) }
            }
            if let ms = message.debounceMs { tracker.debounce = TimeInterval(max(0, ms)) / 1000.0 }
            tracker.reset()
            fadeOutTimer?.invalidate()
            fadeOutTimer = nil
            navigationFadeTimer?.invalidate()
            navigationFadeTimer = nil
            if !isShowing { show() }

        case .deactivate:
            tracker.poke()
            rearmFadeOut()

        case .focusWindow:
            guard let rect = message.rect else { return }
            focusWindow(rect)

        case .pointerMove:
            guard let point = message.point else { return }
            movePointer(to: point, action: message.action ?? .interact)

        case .captureStart:
            guard let id = message.captureId, let rect = message.rect else { return }
            startCapture(id: id, rect: rect)

        case .captureFinish:
            guard let id = message.captureId else { return }
            finishCapture(id: id, success: message.success ?? false)

        case .shutdown:
            navigationFadeTimer?.invalidate()
            navigationWindow?.orderOut(nil)
            pointerWindow?.orderOut(nil)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Window focus and capture animation

    private func focusWindow(_ rect: GlowCaptureRect) {
        guard rect.width > 0, rect.height > 0,
              rect.x.isFinite, rect.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return }

        navigationRect = rect
        navigationGeneration += 1
        let frame = appKitCaptureFrame(rect)

        if let window = navigationWindow, window.targetFrame.equalTo(frame) {
            window.orderFrontRegardless()
            window.outlineView.show(reduceMotion: reduceMotion)
            window.outlineView.refresh(reduceMotion: reduceMotion)
        } else {
            let previous = navigationWindow
            let window = NavigationOutlineWindow(targetFrame: frame, rgba: rgba)
            navigationWindow = window
            window.orderFrontRegardless()
            window.outlineView.show(reduceMotion: reduceMotion)
            previous?.outlineView.hide { [weak previous] in previous?.orderOut(nil) }
        }

        // connect_app and read-only inspection can select a window without an
        // activity scope. Give that standalone selection the same idle grace
        // instead of leaving its outline onscreen indefinitely. An activate
        // message cancels this timer and hands ownership to the shared scope.
        if isShowing {
            navigationFadeTimer?.invalidate()
            navigationFadeTimer = nil
        } else {
            rearmNavigationFade()
        }
    }

    private func rearmNavigationFade() {
        navigationFadeTimer?.invalidate()
        let generation = navigationGeneration
        navigationFadeTimer = Timer.scheduledTimer(
            withTimeInterval: max(0, tracker.debounce),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.hideNavigationOutline(generation: generation) }
        }
    }

    private func hideNavigationOutline(generation: Int) {
        guard generation == navigationGeneration, let window = navigationWindow else { return }
        navigationFadeTimer?.invalidate()
        navigationFadeTimer = nil
        navigationRect = nil
        window.outlineView.hide { [weak self, weak window] in
            guard let self, self.navigationGeneration == generation,
                  self.navigationWindow === window else { return }
            window?.orderOut(nil)
            self.navigationWindow = nil
        }
    }

    private func movePointer(to point: GlowPointerPoint, action: GlowPointerAction) {
        guard point.x.isFinite, point.y.isFinite else { return }
        pointerGeneration += 1
        let target = appKitPointerPoint(point)

        let window: PointerOverlayWindow
        if let existing = pointerWindow {
            window = existing
        } else {
            // The presentation pointer has its own independent history. Its
            // first approach starts near the resolved target—not at the real
            // cursor—and later moves continue from the last synthetic target.
            window = PointerOverlayWindow(
                startPoint: initialPointerPoint(near: target),
                rgba: rgba
            )
            pointerWindow = window
        }

        window.orderFrontRegardless()
        window.pointerView.show(reduceMotion: reduceMotion)
        window.displayIfNeeded()
        window.move(to: target, action: action, reduceMotion: reduceMotion)
    }

    private func hidePointer(generation: Int) {
        guard generation == pointerGeneration, let window = pointerWindow else { return }
        window.pointerView.hide { [weak self, weak window] in
            guard let self, self.pointerGeneration == generation,
                  self.pointerWindow === window else { return }
            window?.orderOut(nil)
        }
    }

    private func startCapture(id: String, rect: GlowCaptureRect) {
        captureTimeouts.removeValue(forKey: id)?.invalidate()
        captureWindows.removeValue(forKey: id)?.orderOut(nil)

        let window = CaptureOverlayWindow(
            targetFrame: appKitCaptureFrame(rect),
            rgba: rgba
        )
        captureWindows[id] = window
        window.orderFrontRegardless()
        window.captureView.start(reduceMotion: reduceMotion)

        // A dead client must not leave a scanning overlay behind indefinitely.
        captureTimeouts[id] = Timer.scheduledTimer(withTimeInterval: 65, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishCapture(id: id, success: false) }
        }
    }

    private func finishCapture(id: String, success: Bool) {
        captureTimeouts.removeValue(forKey: id)?.invalidate()
        guard let window = captureWindows[id] else { return }
        window.captureView.finish(success: success) { [weak self, weak window] in
            guard let self, self.captureWindows[id] === window else { return }
            window?.orderOut(nil)
            self.captureWindows[id] = nil
        }
    }

    // MARK: - Show / hide

    private func show() {
        transitionGeneration += 1
        isShowing = true
        for window in windows {
            window.orderFrontRegardless()
            window.glowView.fadeIn(reduceMotion: reduceMotion)
        }
    }

    private func rearmFadeOut() {
        fadeOutTimer?.invalidate()
        guard let deadline = tracker.fadeOutDeadline() else { return }
        let interval = max(0, deadline.timeIntervalSinceNow)
        fadeOutTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fadeOutFired() }
        }
    }

    private func fadeOutFired() {
        // A poke may have landed while the timer was pending — re-check.
        if tracker.isActive() {
            rearmFadeOut()
            return
        }
        beginFadeOut()
    }

    private func beginFadeOut() {
        fadeOutTimer?.invalidate()
        fadeOutTimer = nil
        guard isShowing else { return }
        isShowing = false
        transitionGeneration += 1
        let generation = transitionGeneration
        navigationFadeTimer?.invalidate()
        navigationFadeTimer = nil
        hideNavigationOutline(generation: navigationGeneration)
        hidePointer(generation: pointerGeneration)
        for window in windows {
            window.glowView.fadeOut { [weak self, weak window] in
                guard let self,
                      self.transitionGeneration == generation,
                      !self.isShowing else { return }
                // Order out and stop all CA work so an idle helper uses ~0% CPU.
                window?.glowView.stopAllAnimation()
                window?.orderOut(nil)
            }
        }
    }

    // MARK: - Screen layout

    private func rebuildWindows() {
        for window in windows {
            window.glowView.stopAllAnimation()
            window.orderOut(nil)
        }
        windows = NSScreen.screens.map { OverlayWindow(screen: $0, rgba: rgba) }
        if isShowing {
            for window in windows {
                window.orderFrontRegardless()
                window.glowView.fadeIn(reduceMotion: reduceMotion)
            }
        }
    }

    @objc private func screenParametersChanged() {
        rebuildWindows()
        if let rect = navigationRect {
            navigationWindow?.move(to: appKitCaptureFrame(rect))
        }
    }

    @objc private func accessibilityOptionsChanged() {
        guard isShowing else { return }
        // Re-apply the current motion preference to already-visible glows.
        for window in windows {
            window.glowView.fadeIn(reduceMotion: reduceMotion)
        }
    }
}
