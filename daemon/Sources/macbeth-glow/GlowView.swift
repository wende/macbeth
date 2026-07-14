import AppKit
import GlowProtocol
import QuartzCore

/// Renders an inner glow hugging all four edges of its host window.
///
/// The glow is a single stroked, blurred rounded rect (`CAShapeLayer` + shadow).
/// The view's own backing layer opacity drives fade-in / fade-out; the shape
/// layer's opacity drives the subtle breathing animation. No Core Animation work
/// runs while the view is hidden — animations are added on show and removed on
/// hide.
final class GlowView: NSView {
    private let glowLayer = CAShapeLayer()
    private var rgba: GlowRGBA

    private static let breathingKey = "glow.breathing"
    private static let fadeKey = "glow.fade"

    init(rgba: GlowRGBA) {
        self.rgba = rgba
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.opacity = 0
        configureLayer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    private func configureLayer() {
        glowLayer.fillColor = nil
        glowLayer.lineWidth = 6
        glowLayer.masksToBounds = false
        glowLayer.shadowRadius = 24
        glowLayer.shadowOpacity = 1
        glowLayer.shadowOffset = .zero
        glowLayer.opacity = 0.9
        applyColor()
        layer?.addSublayer(glowLayer)
    }

    private func applyColor() {
        let color = CGColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: 1)
        glowLayer.strokeColor = color
        glowLayer.shadowColor = color
    }

    func setColor(_ rgba: GlowRGBA) {
        guard rgba != self.rgba else { return }
        self.rgba = rgba
        applyColor()
    }

    override func layout() {
        super.layout()
        updatePath()
    }

    private func updatePath() {
        // A rounded rect inset from the edge; the ~24pt shadow blur spreads the
        // falloff so the glow reads as a soft band hugging the screen edges.
        let inset: CGFloat = 12
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.frame = bounds
        glowLayer.path = CGPath(
            roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil
        )
        CATransaction.commit()
    }

    // MARK: - Show / hide

    /// Fade in quickly (~150ms) and, unless reduced-motion is set, start the
    /// breathing animation.
    func fadeIn(reduceMotion: Bool) {
        layer?.removeAnimation(forKey: Self.fadeKey)
        let current = layer?.presentation()?.opacity ?? layer?.opacity ?? 0
        layer?.opacity = 1

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = 1
        fade.duration = 0.15
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: Self.fadeKey)

        if reduceMotion {
            stopBreathing()
        } else {
            startBreathing()
        }
    }

    /// Fade out slowly (~600ms); `completion` fires when fully hidden so the
    /// window can be ordered out and all animation stopped.
    func fadeOut(completion: @escaping () -> Void) {
        stopBreathing()
        let current = layer?.presentation()?.opacity ?? layer?.opacity ?? 1
        layer?.opacity = 0

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = 0
        fade.duration = 0.6
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
        breathe.duration = 2.0
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(breathe, forKey: Self.breathingKey)
    }

    private func stopBreathing() {
        glowLayer.removeAnimation(forKey: Self.breathingKey)
    }
}
