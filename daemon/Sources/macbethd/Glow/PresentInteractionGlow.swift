@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GlowProtocol

/// Present (or refresh) the window outline for an intentional interaction.
///
/// Call when the target is already frontmost, or **after**
/// `AppConnectionManager.activate` for keyboard / other paths that must
/// foreground the app so HID events land. Background-only AX work should not
/// call this.
///
/// The caller must already hold a glow activity scope (`activityStarted` /
/// `activityEnded`). Use the `scoped:` overload to open one lazily instead.
func presentInteractionGlow(
    glow: GlowIndicator,
    window: AXUIElement?,
    element: AXUIElement? = nil,
    pointerAction: GlowPointerAction? = nil
) async {
    guard let window, let frame = ElementGeometry.frame(of: window) else {
        return
    }

    await glow.windowFocused(
        id: ElementGeometry.windowIdentity(of: window),
        frame: frame
    )

    if let pointerAction,
       let element,
       let point = ElementGeometry.interactionPoint(of: element),
       await glow.pointerMoved(to: point, action: pointerAction) {
        try? await Task.sleep(for: .milliseconds(470))
    }
}

/// Variant for RPCs that only open a glow activity scope if they end up
/// presenting something.
///
/// - Parameters:
///   - scoped: Tracks whether this RPC already opened a scope, so the caller can
///     `activityEnded` exactly once in a `defer`.
func presentInteractionGlow(
    glow: GlowIndicator,
    window: AXUIElement?,
    element: AXUIElement? = nil,
    pointerAction: GlowPointerAction? = nil,
    scoped: inout Bool
) async {
    guard window.flatMap(ElementGeometry.frame(of:)) != nil else { return }

    if !scoped {
        await glow.activityStarted()
        scoped = true
    }

    await presentInteractionGlow(
        glow: glow,
        window: window,
        element: element,
        pointerAction: pointerAction
    )
}
