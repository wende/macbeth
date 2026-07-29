import AppKit
import GlowProtocol

@MainActor
protocol NavigationOverlayWindow: AnyObject {
    var targetFrame: CGRect { get }
    func move(to frame: CGRect)
    func orderFrontRegardless()
    func orderOut(_ sender: Any?)
    @discardableResult
    func showOutline(reduceMotion: Bool) -> Bool
    func hideOutline(completion: @escaping () -> Void)
}

extension NavigationOutlineWindow: NavigationOverlayWindow {
    func showOutline(reduceMotion: Bool) -> Bool {
        outlineView.show(reduceMotion: reduceMotion)
    }

    func hideOutline(completion: @escaping () -> Void) {
        outlineView.hide(completion: completion)
    }
}

typealias NavigationOverlayWindowFactory = @MainActor (CGRect, GlowRGBA) -> any NavigationOverlayWindow

@MainActor
private final class NavigationOverlayState {
    let window: any NavigationOverlayWindow
    var rect: GlowCaptureRect
    var fadeTimer: Timer?
    var fadeDeadline: Date?
    var generation = 0

    init(window: any NavigationOverlayWindow, rect: GlowCaptureRect) {
        self.window = window
        self.rect = rect
    }
}

/// Owns the overlay windows and drives show / hide in response to daemon
/// messages. All methods run on the main thread.
@MainActor
final class OverlayController: NSObject {
    private var rgba: GlowRGBA
    private var tracker: GlowActivityTracker
    private var fadeOutTimer: Timer?
    private var activityActive = false
    private var isShowing = false
    private var captureWindows: [String: CaptureOverlayWindow] = [:]
    private var captureTimeouts: [String: Timer] = [:]
    private var navigationOverlays: [String: NavigationOverlayState] = [:]
    private var activeNavigationIDs: Set<String> = []
    private var pointerWindow: PointerOverlayWindow?
    private var pointerGeneration = 0
    private let navigationWindowFactory: NavigationOverlayWindowFactory
    /// Injectable for tests. Production reads the real frontmost app so a bare
    /// `activate` (MCP `begin_activity`) cannot re-arm outlines on background windows.
    private let frontmostPidProvider: () -> pid_t?

    init(
        rgba: GlowRGBA,
        debounceMs: Int,
        navigationWindowFactory: @escaping NavigationOverlayWindowFactory = {
            NavigationOutlineWindow(targetFrame: $0, rgba: $1)
        },
        frontmostPidProvider: @escaping () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    ) {
        self.rgba = rgba
        self.tracker = GlowActivityTracker(debounceMs: debounceMs)
        self.navigationWindowFactory = navigationWindowFactory
        self.frontmostPidProvider = frontmostPidProvider
        super.init()
    }

    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var navigationOverlayCount: Int { navigationOverlays.count }

    func navigationOutlineWindow(for id: String) -> (any NavigationOverlayWindow)? {
        navigationOverlays[id]?.window
    }

    func navigationFadeIsScheduled(for id: String) -> Bool {
        navigationOverlays[id]?.fadeDeadline != nil
    }

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        // Outlines are only honest while their app is frontmost. When the user
        // (or a test harness) backgrounds a controlled app, drop its outline
        // immediately so residual chrome does not linger on a background window.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    /// Drop navigation outlines whose owning process is no longer frontmost.
    /// Safe to call from tests after changing `frontmostPidProvider`.
    func reconcileOutlinesWithFrontmostApp() {
        // An active scope is a continuity promise. Keep the current outline as a
        // visual buffer during an app hand-off; focusWindow will atomically reveal
        // the new frontmost outline before retiring this one.
        guard !activityActive else { return }
        dismissOutlinesNotBelongingToFrontmostApp()
    }

    // MARK: - Message handling

    func handle(_ message: GlowMessage) {
        switch message.type {
        case .activate:
            activityActive = true
            if let hex = message.color, let parsed = parseGlowColor(hex), parsed != rgba {
                rgba = parsed
            }
            if let ms = message.debounceMs { tracker.debounce = TimeInterval(max(0, ms)) / 1000.0 }
            tracker.reset()
            fadeOutTimer?.invalidate()
            fadeOutTimer = nil
            // Tool calls are sequential, but each call has to resolve its target
            // before it can send focusWindow. Re-arm every buffered outline here:
            // the next focusWindow atomically hands the glow to its target, while
            // an operation that never focuses a window releases it on deactivate.
            for (id, state) in navigationOverlays where state.fadeDeadline != nil {
                state.fadeTimer?.invalidate()
                state.fadeTimer = nil
                state.fadeDeadline = nil
                state.generation += 1
                activeNavigationIDs.insert(id)
            }
            if !isShowing { show() }

        case .deactivate:
            activityActive = false
            tracker.poke()
            rearmFadeOut()
            let activeIDs = activeNavigationIDs
            activeNavigationIDs.removeAll()
            for id in activeIDs {
                rearmNavigationFade(id: id)
            }

        case .focusWindow:
            guard let rect = message.rect else { return }
            let id = message.windowId ?? legacyWindowID(for: rect)
            focusWindow(id: id, rect: rect)

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
            activityActive = false
            for state in navigationOverlays.values {
                state.fadeTimer?.invalidate()
                state.window.orderOut(nil)
            }
            navigationOverlays.removeAll()
            activeNavigationIDs.removeAll()
            pointerWindow?.orderOut(nil)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Window focus and capture animation

    private func focusWindow(id: String, rect: GlowCaptureRect) {
        guard rect.width > 0, rect.height > 0,
              rect.x.isFinite, rect.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return }

        let frame = appKitCaptureFrame(rect)

        let state: NavigationOverlayState
        if let existing = navigationOverlays[id] {
            state = existing
            state.rect = rect
            if !state.window.targetFrame.equalTo(frame) {
                state.window.move(to: frame)
            }
            state.window.orderFrontRegardless()
            state.window.showOutline(reduceMotion: reduceMotion)
        } else {
            let window = navigationWindowFactory(frame, rgba)
            state = NavigationOverlayState(window: window, rect: rect)
            navigationOverlays[id] = state
            window.orderFrontRegardless()
            window.showOutline(reduceMotion: reduceMotion)
        }

        // Identical focus messages are deliberately visually idempotent: they
        // update geometry and lifetime but never restart an animation.
        state.generation += 1
        state.fadeTimer?.invalidate()
        state.fadeTimer = nil
        state.fadeDeadline = nil
        if activityActive {
            activeNavigationIDs.insert(id)
        } else {
            rearmNavigationFade(id: id)
        }

        // During an app hand-off, the previous outline remains visible until the
        // replacement is already on screen. Retire other apps only after showing
        // this outline, producing an overlap/cross-fade instead of a blank frame.
        if let ownerPid = navigationOverlayOwnerPid(id) {
            dismissOutlinesNotBelonging(to: ownerPid)
        }
    }

    private func rearmNavigationFade(id: String) {
        guard let state = navigationOverlays[id] else { return }
        state.fadeTimer?.invalidate()
        state.generation += 1
        let generation = state.generation
        let deadline = Date().addingTimeInterval(max(0, tracker.debounce))
        state.fadeDeadline = deadline
        let timer = Timer.scheduledTimer(
            withTimeInterval: max(0, deadline.timeIntervalSinceNow),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.navigationFadeFired(id: id, generation: generation)
            }
        }
        timer.tolerance = 0
        state.fadeTimer = timer
    }

    private func navigationFadeFired(id: String, generation: Int) {
        guard let state = navigationOverlays[id], state.generation == generation,
              !activeNavigationIDs.contains(id), let deadline = state.fadeDeadline else { return }
        if deadline.timeIntervalSinceNow > 0 {
            let timer = Timer.scheduledTimer(
                withTimeInterval: deadline.timeIntervalSinceNow,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.navigationFadeFired(id: id, generation: generation)
                }
            }
            timer.tolerance = 0
            state.fadeTimer = timer
            return
        }

        state.fadeTimer?.invalidate()
        state.fadeTimer = nil
        state.fadeDeadline = nil
        state.window.hideOutline { [weak self, weak state] in
            guard let self, let state,
                  self.navigationOverlays[id] === state,
                  state.generation == generation,
                  !self.activeNavigationIDs.contains(id) else { return }
            state.window.orderOut(nil)
            self.navigationOverlays[id] = nil
        }
    }

    private func legacyWindowID(for rect: GlowCaptureRect) -> String {
        "legacy:\(rect.x):\(rect.y):\(rect.width):\(rect.height)"
    }

    /// Window ids are `pid:<n>:window:<n>` or `pid:<n>:ax:<hash>` (see ElementGeometry).
    /// Geometry-keyed legacy ids name no owner; nil means "ownership unknown", and
    /// those outlines stay exempt from the frontmost rules below rather than being
    /// treated as belonging to no one and dropped on the next app switch.
    private func navigationOverlayOwnerPid(_ id: String) -> pid_t? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "pid", let pid = pid_t(parts[1]) else { return nil }
        return pid
    }

    @objc private func frontmostApplicationChanged(_ notification: Notification) {
        reconcileOutlinesWithFrontmostApp()
    }

    private func dismissOutlinesNotBelongingToFrontmostApp() {
        guard let frontmostPid = frontmostPidProvider() else { return }
        dismissOutlinesNotBelonging(to: frontmostPid)
    }

    private func dismissOutlinesNotBelonging(to ownerPid: pid_t) {
        let staleIDs = navigationOverlays.keys.filter { id in
            guard let owner = navigationOverlayOwnerPid(id) else { return false }
            return owner != ownerPid
        }
        for id in staleIDs {
            dismissNavigationOutline(id: id)
        }
    }

    /// Tear down a navigation outline now (cancel hold / active scope membership).
    private func dismissNavigationOutline(id: String) {
        guard let state = navigationOverlays[id] else { return }
        activeNavigationIDs.remove(id)
        state.fadeTimer?.invalidate()
        state.fadeTimer = nil
        state.fadeDeadline = nil
        state.generation += 1
        let generation = state.generation
        state.window.hideOutline { [weak self, weak state] in
            guard let self, let state,
                  self.navigationOverlays[id] === state,
                  state.generation == generation else { return }
            state.window.orderOut(nil)
            self.navigationOverlays[id] = nil
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
        isShowing = true
    }

    private func rearmFadeOut() {
        fadeOutTimer?.invalidate()
        guard let deadline = tracker.fadeOutDeadline() else { return }
        let interval = max(0, deadline.timeIntervalSinceNow)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fadeOutFired() }
        }
        timer.tolerance = 0
        fadeOutTimer = timer
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
        hidePointer(generation: pointerGeneration)
    }

    // MARK: - Screen layout

    @objc private func screenParametersChanged() {
        for state in navigationOverlays.values {
            state.window.move(to: appKitCaptureFrame(state.rect))
        }
    }

    @objc private func accessibilityOptionsChanged() {
        // Motion preferences are read on every subsequent show/move/capture.
    }
}

/// AX and ScreenCaptureKit can report sub-point frame differences for the same
/// window across calls. Treat those as one target so the overlay moves in place
/// instead of cross-fading two nearly identical windows.
func approximatelyEqualWindowFrames(
    _ lhs: CGRect,
    _ rhs: CGRect,
    tolerance: CGFloat = 1
) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}
