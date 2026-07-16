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

/// A recording-visible, click-through overlay around exactly the window being
/// captured. Macbeth's screenshot remains clean because ScreenCaptureKit is
/// filtered to the target app's window, while this window belongs to the glow
/// helper process.
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

        // Unlike the ordinary activity glow, this animation should be visible
        // in an external demo recording. A desktop-independent target-window
        // capture still excludes it because it is owned by another process.
        sharingType = .readOnly
        contentView = captureView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A quiet, recording-visible perimeter around the window most recently
/// addressed by MCP. It never accepts input or becomes key, and is replaced
/// when navigation moves to another window.
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

/// The current-target state is intentionally calmer than capture: a fine
/// violet stroke and low halo, with a small pulse when another operation
/// refreshes the same window.
final class NavigationOutlineView: NSView {
    private let innerGlowLayer = CALayer()
    private let innerEdgeLayers = (0..<4).map { _ in CAGradientLayer() }
    private let borderLayer = CAShapeLayer()
    private let haloLayer = CAShapeLayer()
    private var rgba: GlowRGBA

    private static let fadeKey = "navigation.fade"
    private static let pulseKey = "navigation.pulse"
    private static let breathingKey = "navigation.breathing"
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

        innerGlowLayer.masksToBounds = true
        innerGlowLayer.opacity = 0.62
        let colors = [
            color(lightenedBy: 0.2, alpha: 0.5),
            color(lightenedBy: 0.08, alpha: 0.3),
            color(alpha: 0.13),
            color(alpha: 0),
        ]
        innerEdgeLayers.forEach {
            $0.colors = colors
            $0.locations = [0, 0.2, 0.56, 1]
            innerGlowLayer.addSublayer($0)
        }
        root.addSublayer(innerGlowLayer)

        haloLayer.fillColor = NSColor.clear.cgColor
        haloLayer.strokeColor = color(lightenedBy: 0.08, alpha: 0.72)
        haloLayer.lineWidth = 3
        haloLayer.opacity = 0.45
        haloLayer.shadowColor = color(alpha: 0.9)
        haloLayer.shadowOpacity = 0.65
        haloLayer.shadowRadius = 8
        haloLayer.shadowOffset = .zero
        root.addSublayer(haloLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = color(lightenedBy: 0.24, alpha: 0.92)
        borderLayer.lineWidth = 1.5
        borderLayer.opacity = 0.82
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

    func show(reduceMotion: Bool) {
        layoutSubtreeIfNeeded()
        guard let root = layer else { return }
        root.removeAnimation(forKey: Self.fadeKey)
        root.opacity = 1

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = root.presentation()?.opacity ?? 0
        fade.toValue = 1
        fade.duration = reduceMotion ? 0.12 : 0.28
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(fade, forKey: Self.fadeKey)

        if reduceMotion {
            innerGlowLayer.removeAnimation(forKey: Self.breathingKey)
        } else if innerGlowLayer.animation(forKey: Self.breathingKey) == nil {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.42
            breathe.toValue = 0.68
            breathe.duration = 1.2
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            innerGlowLayer.add(breathe, forKey: Self.breathingKey)
        }
    }

    func refresh(reduceMotion: Bool) {
        guard !reduceMotion else { return }
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.82, 1, 0.82]
        pulse.keyTimes = [0, 0.35, 1]
        pulse.duration = 0.42
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        borderLayer.add(pulse, forKey: Self.pulseKey)
    }

    func hide(completion: @escaping () -> Void) {
        guard let root = layer else {
            completion()
            return
        }
        let currentOpacity = root.presentation()?.opacity ?? root.opacity
        root.opacity = 0

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentOpacity
        fade.toValue = 0
        fade.duration = 0.7
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.innerGlowLayer.removeAnimation(forKey: Self.breathingKey)
            completion()
        }
        root.add(fade, forKey: Self.fadeKey)
        CATransaction.commit()
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
            scan.duration = 0.72
            scan.repeatCount = .infinity
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

        scanLayer.removeAnimation(forKey: Self.scanKey)
        borderLayer.removeAnimation(forKey: Self.borderBreatheKey)
        scanLayer.opacity = 0
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
