import AppKit
import GlowProtocol
import QuartzCore

/// Renders an inner glow hugging all four edges of its host window.
///
/// Four edge-aligned gradients keep the brightest color flush with the screen
/// boundary and fade smoothly toward the center. The view's own backing layer
/// opacity drives fade-in / fade-out; the gradient container's opacity drives
/// the subtle breathing animation. No Core Animation work runs while the view
/// is hidden — animations are added on show and removed on hide.
final class GlowView: NSView {
    private let glowLayer = CALayer()
    private let edgeLayers = (0..<4).map { _ in CAGradientLayer() }
    private var rgba: GlowRGBA

    private static let glowDepth: CGFloat = 44
    private static let breathingKey = "glow.breathing"
    private static let fadeKey = "glow.fade"

    init(rgba: GlowRGBA) {
        self.rgba = rgba
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.opacity = 0
        configureLayer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    private func configureLayer() {
        glowLayer.masksToBounds = true
        glowLayer.opacity = 0.9
        edgeLayers.forEach {
            $0.locations = [0, 0.08, 0.24, 0.5, 0.75, 1]
            glowLayer.addSublayer($0)
        }
        applyColor()
        layer?.addSublayer(glowLayer)
    }

    private func applyColor() {
        let colors = [
            color(lightenedBy: 0.18, alpha: 0.92),
            color(lightenedBy: 0.1, alpha: 0.76),
            color(alpha: 0.5),
            color(alpha: 0.22),
            color(alpha: 0.07),
            color(alpha: 0),
        ]
        edgeLayers.forEach { $0.colors = colors }
    }

    private func color(lightenedBy amount: Double = 0, alpha: Double) -> CGColor {
        CGColor(
            red: rgba.red + (1 - rgba.red) * amount,
            green: rgba.green + (1 - rgba.green) * amount,
            blue: rgba.blue + (1 - rgba.blue) * amount,
            alpha: rgba.alpha * alpha
        )
    }

    func setColor(_ rgba: GlowRGBA) {
        guard rgba != self.rgba else { return }
        self.rgba = rgba
        applyColor()
    }

    override func layout() {
        super.layout()
        updateGradients()
    }

    private func updateGradients() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let depth = min(Self.glowDepth, bounds.width / 2, bounds.height / 2)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.frame = bounds

        // AppKit's layer coordinate system starts at the bottom-left. Every
        // gradient begins at its screen edge and ends `depth` points inward.
        configure(
            edgeLayers[0], frame: CGRect(x: 0, y: bounds.height - depth, width: bounds.width, height: depth),
            start: CGPoint(x: 0.5, y: 1), end: CGPoint(x: 0.5, y: 0)
        )
        configure(
            edgeLayers[1], frame: CGRect(x: 0, y: 0, width: bounds.width, height: depth),
            start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1)
        )
        configure(
            edgeLayers[2], frame: CGRect(x: 0, y: 0, width: depth, height: bounds.height),
            start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5)
        )
        configure(
            edgeLayers[3], frame: CGRect(x: bounds.width - depth, y: 0, width: depth, height: bounds.height),
            start: CGPoint(x: 1, y: 0.5), end: CGPoint(x: 0, y: 0.5)
        )
        CATransaction.commit()
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

    // MARK: - Show / hide

    /// Fade in smoothly (~200ms) and, unless reduced-motion is set, start the
    /// breathing animation.
    func fadeIn(reduceMotion: Bool) {
        layer?.removeAnimation(forKey: Self.fadeKey)
        let current = layer?.presentation()?.opacity ?? layer?.opacity ?? 0
        layer?.opacity = 1

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = 1
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: Self.fadeKey)

        if reduceMotion {
            stopBreathing()
        } else {
            startBreathing()
        }
    }

    /// Fade out slowly (~700ms); `completion` fires when fully hidden so the
    /// window can be ordered out and all animation stopped.
    func fadeOut(completion: @escaping () -> Void) {
        // Let the breathing animation ride out the fade with the parent layer —
        // stopping it here would snap glowLayer.opacity back to its model value
        // (0.9) and flicker. It's removed cleanly by stopAllAnimation() once the
        // completion block fires.
        let current = layer?.presentation()?.opacity ?? layer?.opacity ?? 1
        layer?.opacity = 0

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = 0
        fade.duration = 0.7
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer?.add(fade, forKey: Self.fadeKey)
        CATransaction.commit()
    }

    /// Remove every animation so a hidden view does zero Core Animation work.
    func stopAllAnimation() {
        stopBreathing()
        layer?.removeAllAnimations()
    }

    private func startBreathing() {
        guard glowLayer.animation(forKey: Self.breathingKey) == nil else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.55
        breathe.toValue = 0.9
        breathe.duration = 1.0
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(breathe, forKey: Self.breathingKey)
    }

    private func stopBreathing() {
        glowLayer.removeAnimation(forKey: Self.breathingKey)
    }
}
