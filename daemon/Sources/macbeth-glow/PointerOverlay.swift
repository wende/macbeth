import AppKit
import GlowProtocol
import QuartzCore

/// The supplied MCP cursor artwork uses a 128pt design grid. Scale it into the
/// same compact presentation footprint as the previous synthetic pointer.
private let pointerScale: CGFloat = 0.3535533906
private let pointerDesignSize: CGFloat = 128
private let pointerWindowSize = CGSize(
    width: pointerDesignSize * pointerScale,
    height: pointerDesignSize * pointerScale
)
// The SVG pointer's tip is at (18, 13.5) in top-left coordinates. AppKit's
// drawing space is bottom-left, so the corresponding local y is 114.5.
private let pointerHotspot = CGPoint(x: 18 * pointerScale, y: 114.5 * pointerScale)

@MainActor
func appKitPointerPoint(
    _ point: GlowPointerPoint,
    primaryDisplayTop: CGFloat? = nil
) -> CGPoint {
    let top = primaryDisplayTop ?? NSScreen.screens.first?.frame.maxY ?? 0
    return CGPoint(x: point.x, y: Double(top) - point.y)
}

/// Give the first target a short, visible approach without borrowing the real
/// cursor's position. Keep the whole pointer window on the target's display.
@MainActor
func initialPointerPoint(near target: CGPoint, screens: [NSScreen]? = nil) -> CGPoint {
    let availableScreens = screens ?? NSScreen.screens
    let screen = availableScreens.first(where: { $0.frame.contains(target) })
        ?? availableScreens.first
    let preferred = CGPoint(
        x: target.x - 96 * pointerScale,
        y: target.y + 78 * pointerScale
    )
    guard let visible = screen?.visibleFrame.insetBy(dx: 32, dy: 32) else {
        return preferred
    }
    return CGPoint(
        x: min(max(preferred.x, visible.minX), visible.maxX),
        y: min(max(preferred.y, visible.minY), visible.maxY)
    )
}

/// A click-through synthetic pointer. It stays visible in external screen
/// recordings but is excluded from Macbeth's own single-window screenshots. It
/// is deliberately violet-tinted rather than impersonating the system cursor
/// exactly, making it clear that it represents Macbeth's intended target while
/// leaving the real pointer alone.
final class PointerOverlayWindow: NSWindow {
    let pointerView: PointerOverlayView
    private(set) var targetPoint: CGPoint
    private var movementTimer: Timer?
    private var movementStartedAt: CFTimeInterval = 0
    private var movementDuration: TimeInterval = 0
    private var movementStartOrigin = CGPoint.zero
    private var movementEndOrigin = CGPoint.zero
    private var pendingAction: GlowPointerAction = .interact

    init(startPoint: CGPoint, rgba: GlowRGBA) {
        targetPoint = startPoint
        pointerView = PointerOverlayView(rgba: rgba)
        super.init(
            contentRect: Self.frame(around: startPoint),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = .readOnly
        contentView = pointerView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func move(
        to point: CGPoint,
        action: GlowPointerAction,
        reduceMotion: Bool
    ) {
        let distance = hypot(point.x - targetPoint.x, point.y - targetPoint.y)
        targetPoint = point
        let duration = reduceMotion ? 0.01 : min(0.44, max(0.26, Double(distance / 1_800)))
        let destination = Self.frame(around: point).origin

        movementTimer?.invalidate()
        movementTimer = nil

        if reduceMotion {
            setFrameOrigin(destination)
            pointerView.arrived(action: action, reduceMotion: true)
            return
        }

        // NSWindow's animator proxy can commit the destination frame without
        // producing visible intermediate frames for high-level overlay windows.
        // Drive the origin explicitly so recordings always show actual travel.
        movementStartOrigin = frame.origin
        movementEndOrigin = destination
        movementStartedAt = CACurrentMediaTime()
        movementDuration = duration
        pendingAction = action
        movementTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(stepMovement(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func stepMovement(_ timer: Timer) {
        let elapsed = CACurrentMediaTime() - movementStartedAt
        let linear = min(1, max(0, elapsed / movementDuration))
        let eased: Double
        if linear < 0.5 {
            eased = 4 * linear * linear * linear
        } else {
            eased = 1 - pow(-2 * linear + 2, 3) / 2
        }

        setFrameOrigin(CGPoint(
            x: movementStartOrigin.x
                + (movementEndOrigin.x - movementStartOrigin.x) * eased,
            y: movementStartOrigin.y
                + (movementEndOrigin.y - movementStartOrigin.y) * eased
        ))

        guard linear >= 1 else { return }
        timer.invalidate()
        movementTimer = nil
        setFrameOrigin(movementEndOrigin)
        pointerView.arrived(action: pendingAction, reduceMotion: false)
    }

    private static func frame(around point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - pointerHotspot.x,
            y: point.y - pointerHotspot.y,
            width: pointerWindowSize.width,
            height: pointerWindowSize.height
        )
    }
}

final class PointerOverlayView: NSView {
    private let cursorGradientLayer = CAGradientLayer()
    private let pointerStrokeLayer = CAShapeLayer()
    private let daggerCutLayer = CAShapeLayer()
    private let pulseLayer = CAShapeLayer()
    private let fillCaretLayer = CAShapeLayer()
    private var rgba: GlowRGBA

    init(rgba: GlowRGBA) {
        self.rgba = rgba
        super.init(frame: CGRect(origin: .zero, size: pointerWindowSize))
        wantsLayer = true
        layer?.opacity = 0
        layer?.masksToBounds = false
        configureLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // The backing layer receives its final bounds when the click-through
        // overlay window is ordered on screen. Keep the SVG-derived gradient in
        // sync; setting it only during init can leave it at a zero-sized frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorGradientLayer.frame = bounds
        CATransaction.commit()
    }

    private func configureLayers() {
        guard let root = layer else { return }

        let cursorPath = transformedPointerPath()
        let cursorMask = CAShapeLayer()
        cursorMask.path = cursorPath
        cursorMask.fillColor = NSColor.white.cgColor

        cursorGradientLayer.frame = bounds
        cursorGradientLayer.colors = [
            CGColor(red: 0x8B / 255, green: 0x33 / 255, blue: 0x42 / 255, alpha: 1),
            CGColor(red: 0x61 / 255, green: 0x20 / 255, blue: 0x2F / 255, alpha: 1),
            CGColor(red: 0x32 / 255, green: 0x11 / 255, blue: 0x1A / 255, alpha: 1),
        ]
        cursorGradientLayer.locations = [0, 0.5, 1]
        cursorGradientLayer.startPoint = CGPoint(x: 28 / pointerDesignSize, y: 110 / pointerDesignSize)
        cursorGradientLayer.endPoint = CGPoint(x: 87 / pointerDesignSize, y: 24 / pointerDesignSize)
        cursorGradientLayer.mask = cursorMask
        root.addSublayer(cursorGradientLayer)

        pointerStrokeLayer.path = cursorPath
        pointerStrokeLayer.fillColor = NSColor.clear.cgColor
        pointerStrokeLayer.strokeColor = CGColor(red: 0xF8 / 255, green: 0xF7 / 255, blue: 0xFA / 255, alpha: 1)
        pointerStrokeLayer.lineWidth = 6 * pointerScale
        pointerStrokeLayer.lineJoin = .round
        pointerStrokeLayer.shadowColor = CGColor(red: 0x09 / 255, green: 0x06 / 255, blue: 0x12 / 255, alpha: 1)
        pointerStrokeLayer.shadowOpacity = 0.35
        pointerStrokeLayer.shadowRadius = 3 * pointerScale
        pointerStrokeLayer.shadowOffset = CGSize(width: 0, height: -4 * pointerScale)
        root.addSublayer(pointerStrokeLayer)

        daggerCutLayer.path = transformedDaggerCutPath()
        daggerCutLayer.fillColor = CGColor(red: 0xF4 / 255, green: 0xF1 / 255, blue: 0xF8 / 255, alpha: 0.09)
        root.addSublayer(daggerCutLayer)

        let pulseRect = CGRect(
            x: pointerHotspot.x - 9 * pointerScale,
            y: pointerHotspot.y - 9 * pointerScale,
            width: 18 * pointerScale,
            height: 18 * pointerScale
        )
        pulseLayer.path = CGPath(ellipseIn: pulseRect, transform: nil)
        pulseLayer.fillColor = NSColor.clear.cgColor
        pulseLayer.strokeColor = color(lightenedBy: 0.32, alpha: 0.95)
        pulseLayer.lineWidth = 2.5 * pointerScale
        pulseLayer.opacity = 0
        root.addSublayer(pulseLayer)

        let caret = CGMutablePath()
        caret.move(to: CGPoint(x: pointerHotspot.x - 4 * pointerScale, y: pointerHotspot.y - 9 * pointerScale))
        caret.addLine(to: CGPoint(x: pointerHotspot.x + 4 * pointerScale, y: pointerHotspot.y - 9 * pointerScale))
        caret.move(to: CGPoint(x: pointerHotspot.x, y: pointerHotspot.y - 9 * pointerScale))
        caret.addLine(to: CGPoint(x: pointerHotspot.x, y: pointerHotspot.y + 9 * pointerScale))
        caret.move(to: CGPoint(x: pointerHotspot.x - 4 * pointerScale, y: pointerHotspot.y + 9 * pointerScale))
        caret.addLine(to: CGPoint(x: pointerHotspot.x + 4 * pointerScale, y: pointerHotspot.y + 9 * pointerScale))
        fillCaretLayer.path = caret
        fillCaretLayer.fillColor = NSColor.clear.cgColor
        fillCaretLayer.strokeColor = color(lightenedBy: 0.5, alpha: 1)
        fillCaretLayer.lineWidth = 2 * pointerScale
        fillCaretLayer.opacity = 0
        root.addSublayer(fillCaretLayer)
    }

    private func transformedPointerPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 18, y: 13.5))
        path.addLine(to: CGPoint(x: 18, y: 95.7))
        path.addCurve(
            to: CGPoint(x: 25.8, y: 98.8),
            control1: CGPoint(x: 18, y: 99.8),
            control2: CGPoint(x: 23, y: 101.8)
        )
        path.addLine(to: CGPoint(x: 44, y: 79.4))
        path.addLine(to: CGPoint(x: 57.1, y: 107.5))
        path.addCurve(
            to: CGPoint(x: 63.5, y: 109.8),
            control1: CGPoint(x: 58.2, y: 109.9),
            control2: CGPoint(x: 61.1, y: 110.9)
        )
        path.addLine(to: CGPoint(x: 75.7, y: 104.1))
        path.addCurve(
            to: CGPoint(x: 78, y: 97.7),
            control1: CGPoint(x: 78.1, y: 103),
            control2: CGPoint(x: 79.1, y: 100.1)
        )
        path.addLine(to: CGPoint(x: 65.2, y: 70.2))
        path.addLine(to: CGPoint(x: 90.7, y: 70.2))
        path.addCurve(
            to: CGPoint(x: 93.6, y: 62.3),
            control1: CGPoint(x: 94.9, y: 70.2),
            control2: CGPoint(x: 96.9, y: 64.9)
        )
        path.addLine(to: CGPoint(x: 25.4, y: 9.9))
        path.addCurve(
            to: CGPoint(x: 18, y: 13.5),
            control1: CGPoint(x: 22.4, y: 7.6),
            control2: CGPoint(x: 18, y: 9.7)
        )
        path.closeSubpath()
        return flippedAndScaled(path)
    }

    private func transformedDaggerCutPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 30, y: 28))
        path.addLine(to: CGPoint(x: 73, y: 61))
        path.addLine(to: CGPoint(x: 54.9, y: 61))
        path.addLine(to: CGPoint(x: 70.7, y: 95))
        path.addLine(to: CGPoint(x: 63.6, y: 98.3))
        path.addLine(to: CGPoint(x: 47.6, y: 63.9))
        path.addLine(to: CGPoint(x: 30, y: 82))
        path.closeSubpath()
        return flippedAndScaled(path)
    }

    private func flippedAndScaled(_ path: CGPath) -> CGPath {
        var transform = CGAffineTransform(
            a: pointerScale,
            b: 0,
            c: 0,
            d: -pointerScale,
            tx: 0,
            ty: pointerDesignSize * pointerScale
        )
        return path.copy(using: &transform) ?? path
    }

    func show(reduceMotion: Bool) {
        guard let root = layer else { return }
        let current = root.presentation()?.opacity ?? root.opacity
        root.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = 1
        fade.duration = reduceMotion ? 0.08 : 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(fade, forKey: "pointer.fade")
    }

    func arrived(action: GlowPointerAction, reduceMotion: Bool) {
        guard !reduceMotion else { return }

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 0]
        pulse.keyTimes = [0, 0.22, 1]
        pulse.duration = 0.46
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.55
        scale.toValue = 1.65
        scale.duration = 0.46
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let targetLayer = action == .fill ? fillCaretLayer : pulseLayer
        targetLayer.add(pulse, forKey: "pointer.arrival.opacity")
        if action != .fill {
            targetLayer.add(scale, forKey: "pointer.arrival.scale")
        }
    }

    func hide(completion: @escaping () -> Void) {
        guard let root = layer else {
            completion()
            return
        }
        let current = root.presentation()?.opacity ?? root.opacity
        root.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = 0
        // Keep this interruptible so the next operation can resume the same
        // synthetic pointer without blinking between paced demo calls.
        fade.duration = 0.7
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        root.add(fade, forKey: "pointer.fade")
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
