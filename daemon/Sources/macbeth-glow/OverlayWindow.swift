import AppKit
import GlowProtocol

/// A borderless, click-through overlay window that covers exactly one screen.
///
/// It floats above normal (and full-screen) content, joins every Space, never
/// intercepts input, and is excluded from screen sharing / capture via
/// `sharingType = .none` — so the agent's own screenshots never see the glow.
final class OverlayWindow: NSWindow {
    let glowView: GlowView

    init(screen: NSScreen, rgba: GlowRGBA) {
        glowView = GlowView(rgba: rgba)
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Must never intercept clicks or key input, anywhere on screen.
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        // Float above assistive tech / most system UI, including full-screen apps.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Keep the glow out of any screen recording / ScreenCaptureKit capture.
        sharingType = .none

        contentView = glowView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }
}
