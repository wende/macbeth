import AppKit
import GlowProtocol
import QuartzCore

// A 50% area reduction means each linear dimension is scaled by √½, not ½.
private let pointerScale: CGFloat = 0.7071067812
private let pointerWindowSize = CGSize(width: 64 * pointerScale, height: 64 * pointerScale)
private let pointerHotspot = CGPoint(x: 16 * pointerScale, y: 52 * pointerScale)

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
        x: target.x - 52 * pointerScale,
        y: target.y + 42 * pointerScale
    )
    guard let visible = screen?.visibleFrame.insetBy(dx: 32, dy: 32) else {
        return preferred
    }
    return CGPoint(
        x: min(max(preferred.x, visible.minX), visible.maxX),
        y: min(max(preferred.y, visible.minY), visible.maxY)
    )
}

/// A click-through, recording-only pointer. It is deliberately violet-tinted
/// rather than impersonating the system cursor exactly, making it clear that it
/// represents Macbeth's intended target while leaving the real pointer alone.
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
    private let badgeLayer = CAShapeLayer()
    private let pointerLayer = CAShapeLayer()
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

    private func configureLayers() {
        guard let root = layer else { return }

        badgeLayer.path = CGPath(
            ellipseIn: CGRect(
                x: 3 * pointerScale,
                y: 7 * pointerScale,
                width: 48 * pointerScale,
                height: 48 * pointerScale
            ),
            transform: nil
        )
        badgeLayer.fillColor = color(alpha: 0.2)
        badgeLayer.strokeColor = color(lightenedBy: 0.38, alpha: 0.56)
        badgeLayer.lineWidth = 1.5 * pointerScale
        badgeLayer.shadowColor = color(alpha: 1)
        badgeLayer.shadowOpacity = 0.55
        badgeLayer.shadowRadius = 10 * pointerScale
        badgeLayer.shadowOffset = .zero
        root.addSublayer(badgeLayer)

        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 16 * pointerScale, y: 52 * pointerScale))
        arrow.addLine(to: CGPoint(x: 17 * pointerScale, y: 17 * pointerScale))
        arrow.addLine(to: CGPoint(x: 25 * pointerScale, y: 25 * pointerScale))
        arrow.addLine(to: CGPoint(x: 32 * pointerScale, y: 11 * pointerScale))
        arrow.addLine(to: CGPoint(x: 39 * pointerScale, y: 15 * pointerScale))
        arrow.addLine(to: CGPoint(x: 31 * pointerScale, y: 29 * pointerScale))
        arrow.addLine(to: CGPoint(x: 43 * pointerScale, y: 29 * pointerScale))
        arrow.closeSubpath()

        pointerLayer.path = arrow
        pointerLayer.fillColor = color(lightenedBy: 0.48, alpha: 0.98)
        pointerLayer.strokeColor = CGColor(gray: 0.12, alpha: 0.95)
        pointerLayer.lineWidth = 2 * pointerScale
        pointerLayer.lineJoin = .round
        pointerLayer.shadowColor = color(alpha: 1)
        pointerLayer.shadowOpacity = 0.9
        pointerLayer.shadowRadius = 7 * pointerScale
        pointerLayer.shadowOffset = .zero
        root.addSublayer(pointerLayer)

        let pulseRect = CGRect(
            x: 7 * pointerScale,
            y: 43 * pointerScale,
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
        caret.move(to: CGPoint(x: 12 * pointerScale, y: 42 * pointerScale))
        caret.addLine(to: CGPoint(x: 20 * pointerScale, y: 42 * pointerScale))
        caret.move(to: CGPoint(x: 16 * pointerScale, y: 42 * pointerScale))
        caret.addLine(to: CGPoint(x: 16 * pointerScale, y: 60 * pointerScale))
        caret.move(to: CGPoint(x: 12 * pointerScale, y: 60 * pointerScale))
        caret.addLine(to: CGPoint(x: 20 * pointerScale, y: 60 * pointerScale))
        fillCaretLayer.path = caret
        fillCaretLayer.fillColor = NSColor.clear.cgColor
        fillCaretLayer.strokeColor = color(lightenedBy: 0.5, alpha: 1)
        fillCaretLayer.lineWidth = 2 * pointerScale
        fillCaretLayer.opacity = 0
        root.addSublayer(fillCaretLayer)
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
        // Match the screen glow's fade so the next operation can interrupt and
        // resume it without the pointer blinking out between paced demo calls.
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
