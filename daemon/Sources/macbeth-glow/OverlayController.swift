import AppKit
import GlowProtocol

/// Owns the overlay windows and drives show / hide in response to daemon
/// messages. All methods run on the main thread.
@MainActor
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private var rgba: GlowRGBA
    private var tracker: GlowActivityTracker
    private var fadeOutTimer: Timer?
    private var isShowing = false

    init(rgba: GlowRGBA, debounceMs: Int) {
        self.rgba = rgba
        self.tracker = GlowActivityTracker(debounceMs: debounceMs)
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
            let wasIdle = tracker.poke()
            if wasIdle || !isShowing { show() }
            rearmFadeOut()

        case .deactivate:
            tracker.reset()
            beginFadeOut()

        case .shutdown:
            NSApp.terminate(nil)
        }
    }

    // MARK: - Show / hide

    private func show() {
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
        for window in windows {
            window.glowView.fadeOut { [weak window] in
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
    }

    @objc private func accessibilityOptionsChanged() {
        guard isShowing else { return }
        // Re-apply the current motion preference to already-visible glows.
        for window in windows {
            window.glowView.fadeIn(reduceMotion: reduceMotion)
        }
    }
}
