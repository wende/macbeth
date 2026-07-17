import AppKit
import GlowProtocol
import QuartzCore

private let capturePadding: CGFloat = 18
private let navigationPadding: CGFloat = 12

/// Convert ScreenCaptureKit/CoreGraphics global coordinates (top-left origin)
/// to AppKit global coordinates (bottom-left origin).
@MainActor
func appKitCaptureFrame(
    _ rect: GlowCaptureRect,
    primaryDisplayTop: CGFloat? = nil
) -> CGRect {
    let top = primaryDisplayTop ?? NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(
        x: rect.x,
        y: Double(top) - rect.y - rect.height,
        width: rect.width,
        height: rect.height
    )
}

/// A click-through overlay around exactly the window being captured. It stays
/// visible in external screen recordings — the point of the visibility feature —
/// but Macbeth's own screenshots exclude it: those filter to a single target
/// window, and this is a separate window owned by the macbeth-glow process.
final class CaptureOverlayWindow: NSWindow {
    let captureView: CaptureOverlayView

    init(targetFrame: CGRect, rgba: GlowRGBA) {
        let overlayFrame = targetFrame.insetBy(dx: -capturePadding, dy: -capturePadding)
        captureView = CaptureOverlayView(rgba: rgba)
        super.init(
            contentRect: overlayFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Stay visible in external screen recordings. Macbeth's own screenshots
        // are unaffected because they filter to the single target window, and
        // this is a separate helper-process window.
        sharingType = .readOnly
        contentView = captureView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A quiet perimeter around one window addressed by MCP. It never accepts input
/// or becomes key; the controller may retain several instances simultaneously.
final class NavigationOutlineWindow: NSWindow {
    let outlineView: NavigationOutlineView
    private(set) var targetFrame: CGRect

    init(targetFrame: CGRect, rgba: GlowRGBA) {
        self.targetFrame = targetFrame
        outlineView = NavigationOutlineView(rgba: rgba)
        super.init(
            contentRect: targetFrame.insetBy(dx: -navigationPadding, dy: -navigationPadding),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .readOnly
        contentView = outlineView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func move(to frame: CGRect) {
        targetFrame = frame
        setFrame(frame.insetBy(dx: -navigationPadding, dy: -navigationPadding), display: true)
    }
}

/// The controlled-window state is intentionally calmer than capture: a static
/// fine burgundy stroke, low halo, and inward glow — same shape as the original
/// dark treatment, with brighter / more saturated stops so it doesn't read muddy.
final class NavigationOutlineView: NSView {
    private let innerGlowLayer = CALayer()
    private let innerEdgeLayers = (0..<4).map { _ in CAGradientLayer() }
    private let borderLayer = CAShapeLayer()
    private let haloLayer = CAShapeLayer()
    private var rgba: GlowRGBA
    private var isShown = false
    private var visibilityGeneration = 0

    private static let fadeKey = "navigation.fade"
    private static let innerGlowDepth: CGFloat = 32

    init(rgba: GlowRGBA) {
        self.rgba = rgba
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.opacity = 0
        configureLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let target = bounds.insetBy(dx: navigationPadding, dy: navigationPadding)
        let path = CGPath(roundedRect: target, cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        innerGlowLayer.frame = target
        innerGlowLayer.cornerRadius = 12
        updateInnerGradients(in: innerGlowLayer.bounds)
        borderLayer.frame = bounds
        borderLayer.path = path
        haloLayer.frame = bounds
        haloLayer.path = path
        CATransaction.commit()
    }

    private func configureLayers() {
        guard let root = layer else { return }

        // Same stop layout as the original dark glow, but each stop is lifted
        // (brighter + more chroma) and alphas are a notch higher so the wash
        // reads vivid rather than brown-muddy on light window chrome.
        innerGlowLayer.masksToBounds = true
        innerGlowLayer.opacity = 0.82
        let colors = [
            color(lightenedBy: 0.38, vividBoost: 0.35, alpha: 0.62),
            color(lightenedBy: 0.18, vividBoost: 0.4, alpha: 0.42),
            color(lightenedBy: 0.04, vividBoost: 0.45, alpha: 0.22),
            color(vividBoost: 0.35, alpha: 0),
        ]
        innerEdgeLayers.forEach {
            $0.colors = colors
            $0.locations = [0, 0.2, 0.56, 1]
            innerGlowLayer.addSublayer($0)
        }
        root.addSublayer(innerGlowLayer)

        haloLayer.fillColor = NSColor.clear.cgColor
        haloLayer.strokeColor = color(lightenedBy: 0.22, vividBoost: 0.4, alpha: 0.82)
        haloLayer.lineWidth = 3
        haloLayer.opacity = 0.55
        haloLayer.shadowColor = color(vividBoost: 0.45, alpha: 0.95)
        haloLayer.shadowOpacity = 0.75
        haloLayer.shadowRadius = 10
        haloLayer.shadowOffset = .zero
        root.addSublayer(haloLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = color(lightenedBy: 0.4, vividBoost: 0.35, alpha: 0.98)
        borderLayer.lineWidth = 1.5
        borderLayer.opacity = 0.92
        root.addSublayer(borderLayer)
    }

    private func updateInnerGradients(in bounds: CGRect) {
        let depth = min(Self.innerGlowDepth, bounds.width / 2, bounds.height / 2)
        configure(
            innerEdgeLayers[0],
            frame: CGRect(x: 0, y: bounds.height - depth, width: bounds.width, height: depth),
            start: CGPoint(x: 0.5, y: 1), end: CGPoint(x: 0.5, y: 0)
        )
        configure(
            innerEdgeLayers[1],
            frame: CGRect(x: 0, y: 0, width: bounds.width, height: depth),
            start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1)
        )
        configure(
            innerEdgeLayers[2],
            frame: CGRect(x: 0, y: 0, width: depth, height: bounds.height),
            start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5)
        )
        configure(
            innerEdgeLayers[3],
            frame: CGRect(x: bounds.width - depth, y: 0, width: depth, height: bounds.height),
            start: CGPoint(x: 1, y: 0.5), end: CGPoint(x: 0, y: 0.5)
        )
    }

    private func configure(
        _ gradient: CAGradientLayer,
        frame: CGRect,
        start: CGPoint,
        end: CGPoint
    ) {
        gradient.frame = frame
        gradient.startPoint = start
        gradient.endPoint = end
    }

    /// Reveal the outline if needed. Repeated focus messages while it is fully
    /// visible do not restart fade-in. If a focus arrives during fade-out, the
    /// animation reverses smoothly from the opacity currently on screen.
    @discardableResult
    func show(reduceMotion: Bool) -> Bool {
        layoutSubtreeIfNeeded()
        guard let root = layer else { return false }
        // A focus refresh for an already-present window is state-only. Do not
        // replace an in-flight fade-in or create any other visual pulse.
        guard !isShown else { return false }
        let currentOpacity = root.presentation()?.opacity ?? root.opacity
        visibilityGeneration += 1
        root.removeAnimation(forKey: Self.fadeKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = 1
        CATransaction.commit()
        isShown = true

        let needsReveal = currentOpacity < 0.999
        if needsReveal {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = currentOpacity
            fade.toValue = 1
            fade.duration = reduceMotion ? 0.12 : 0.28
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            root.add(fade, forKey: Self.fadeKey)
        }

        return needsReveal
    }

    func hide(completion: @escaping () -> Void) {
        guard let root = layer else {
            completion()
            return
        }
        let currentOpacity = root.presentation()?.opacity ?? root.opacity
        visibilityGeneration += 1
        let generation = visibilityGeneration
        isShown = false
        root.removeAnimation(forKey: Self.fadeKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = 0
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentOpacity
        fade.toValue = 0
        fade.duration = glowWindowFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self,
                  self.visibilityGeneration == generation,
                  !self.isShown else { return }
            completion()
        }
        root.add(fade, forKey: Self.fadeKey)
        CATransaction.commit()
    }

    private func color(
        lightenedBy amount: Double = 0,
        vividBoost: Double = 0,
        alpha: Double
    ) -> CGColor {
        // Lift toward white, then push chroma back up so "brighter" stays
        // burgundy instead of washing out to dusty pink/grey.
        var r = rgba.red + (1 - rgba.red) * amount
        var g = rgba.green + (1 - rgba.green) * amount
        var b = rgba.blue + (1 - rgba.blue) * amount
        if vividBoost > 0 {
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let mid = (maxC + minC) / 2
            if maxC > minC {
                r = min(1, mid + (r - mid) * (1 + vividBoost))
                g = min(1, mid + (g - mid) * (1 + vividBoost))
                b = min(1, mid + (b - mid) * (1 + vividBoost))
            }
            // Small value lift so saturated stops still feel luminous.
            let lift = 0.08 * vividBoost
            r = min(1, r + lift)
            g = min(1, g + lift * 0.35)
            b = min(1, b + lift * 0.45)
        }
        return CGColor(red: r, green: g, blue: b, alpha: rgba.alpha * alpha)
    }
}

/// A restrained camera-like animation: the target softly focuses, a luminous
/// scan line crosses it, then a short snap flash dissolves the frame.
final class CaptureOverlayView: NSView {
    private let washLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let scanLayer = CAGradientLayer()
    private var rgba: GlowRGBA

    private static let rootFadeKey = "capture.rootFade"
    private static let rootScaleKey = "capture.rootScale"
    private static let borderBreatheKey = "capture.borderBreathe"
    private static let scanKey = "capture.scan"
    private static let snapKey = "capture.snap"

    init(rgba: GlowRGBA) {
        self.rgba = rgba
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.opacity = 0
        configureLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let target = bounds.insetBy(dx: capturePadding, dy: capturePadding)
        let path = CGPath(roundedRect: target, cornerWidth: 13, cornerHeight: 13, transform: nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        washLayer.frame = bounds
        washLayer.mask = shapeMask(path: path, frame: bounds)
        borderLayer.frame = bounds
        borderLayer.path = path
        scanLayer.frame = CGRect(
            x: target.minX + 10,
            y: target.maxY - 2.5,
            width: max(1, target.width - 20),
            height: 5
        )
        CATransaction.commit()
    }

    private func configureLayers() {
        guard let root = layer else { return }
        let accent = color(lightenedBy: 0.2, alpha: 1)

        washLayer.backgroundColor = color(alpha: 0.12)
        washLayer.opacity = 0
        root.addSublayer(washLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = accent
        borderLayer.lineWidth = 2.5
        borderLayer.opacity = 0.9
        borderLayer.shadowColor = color(alpha: 0.9)
        borderLayer.shadowOpacity = 0.75
        borderLayer.shadowRadius = 10
        borderLayer.shadowOffset = .zero
        root.addSublayer(borderLayer)

        scanLayer.colors = [
            color(alpha: 0),
            color(lightenedBy: 0.35, alpha: 0.95),
            color(alpha: 0),
        ]
        scanLayer.locations = [0, 0.5, 1]
        scanLayer.startPoint = CGPoint(x: 0, y: 0.5)
        scanLayer.endPoint = CGPoint(x: 1, y: 0.5)
        scanLayer.shadowColor = color(alpha: 1)
        scanLayer.shadowOpacity = 0.9
        scanLayer.shadowRadius = 9
        scanLayer.shadowOffset = .zero
        root.addSublayer(scanLayer)
    }

    func start(reduceMotion: Bool) {
        layoutSubtreeIfNeeded()
        guard let root = layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = 1
        root.setAffineTransform(.identity)
        scanLayer.opacity = reduceMotion ? 0.45 : 0.9
        washLayer.opacity = 0
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(fade, forKey: Self.rootFadeKey)

        if !reduceMotion {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.992
            scale.toValue = 1
            scale.duration = 0.24
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            root.add(scale, forKey: Self.rootScaleKey)

            let scan = CABasicAnimation(keyPath: "position.y")
            scan.fromValue = bounds.maxY - capturePadding
            scan.toValue = capturePadding
            scan.duration = glowCaptureScanDuration
            // Exactly one pass. Keep its presentation at the bottom until the
            // capture completes instead of wrapping into a partial second pass.
            scan.fillMode = .forwards
            scan.isRemovedOnCompletion = false
            scan.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scanLayer.add(scan, forKey: Self.scanKey)

            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.65
            breathe.toValue = 1
            breathe.duration = 0.7
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            borderLayer.add(breathe, forKey: Self.borderBreatheKey)
        }

        let focusFlash = CAKeyframeAnimation(keyPath: "opacity")
        focusFlash.values = [0, 0.16, 0]
        focusFlash.keyTimes = [0, 0.45, 1]
        focusFlash.duration = 0.34
        focusFlash.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        washLayer.add(focusFlash, forKey: "capture.focusFlash")
    }

    func finish(success: Bool, completion: @escaping () -> Void) {
        guard let root = layer else {
            completion()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scanLayer.opacity = 0
        CATransaction.commit()
        scanLayer.removeAnimation(forKey: Self.scanKey)
        borderLayer.removeAnimation(forKey: Self.borderBreatheKey)
        borderLayer.opacity = 1
        borderLayer.strokeColor = success
            ? color(lightenedBy: 0.55, alpha: 1)
            : CGColor(red: 1, green: 0.3, blue: 0.34, alpha: 1)

        let snap = CAKeyframeAnimation(keyPath: "opacity")
        snap.values = [0, success ? 0.46 : 0.24, success ? 0.18 : 0.1, 0]
        snap.keyTimes = [0, 0.14, 0.48, 1]
        snap.duration = 0.58
        snap.timingFunction = CAMediaTimingFunction(name: .easeOut)
        washLayer.add(snap, forKey: Self.snapKey)

        let borderSnap = CAKeyframeAnimation(keyPath: "lineWidth")
        borderSnap.values = [2.5, success ? 6.5 : 5, 3]
        borderSnap.keyTimes = [0, 0.18, 1]
        borderSnap.duration = 0.58
        borderSnap.timingFunction = CAMediaTimingFunction(name: .easeOut)
        borderLayer.add(borderSnap, forKey: "capture.borderSnap")

        root.removeAnimation(forKey: Self.rootFadeKey)
        let currentOpacity = root.presentation()?.opacity ?? root.opacity
        root.opacity = 0

        let dissolve = CABasicAnimation(keyPath: "opacity")
        dissolve.fromValue = currentOpacity
        dissolve.toValue = 0
        dissolve.beginTime = CACurrentMediaTime() + 0.16
        dissolve.duration = 0.66
        dissolve.fillMode = .backwards
        dissolve.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let settle = CABasicAnimation(keyPath: "transform.scale")
        settle.fromValue = 1
        settle.toValue = success ? 1.006 : 0.996
        settle.beginTime = dissolve.beginTime
        settle.duration = dissolve.duration
        settle.fillMode = .backwards
        settle.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        root.add(dissolve, forKey: Self.rootFadeKey)
        root.add(settle, forKey: Self.rootScaleKey)
        CATransaction.commit()
    }

    private func shapeMask(path: CGPath, frame: CGRect) -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.frame = frame
        mask.path = path
        mask.fillColor = NSColor.white.cgColor
        return mask
    }

    private func color(lightenedBy amount: Double = 0, alpha: Double) -> CGColor {
        CGColor(
            red: rgba.red + (1 - rgba.red) * amount,
            green: rgba.green + (1 - rgba.green) * amount,
            blue: rgba.blue + (1 - rgba.blue) * amount,
            alpha: rgba.alpha * alpha
        )
    }
}
