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
/// - Parameters:
///   - scoped: Tracks whether this RPC already opened a glow activity scope so
///     callers can `activityEnded` exactly once in a `defer`.
@discardableResult
func presentInteractionGlow(
    glow: GlowIndicator,
    window: AXUIElement?,
    element: AXUIElement? = nil,
    pointerAction: GlowPointerAction? = nil,
    scoped: inout Bool
) async -> Bool {
    guard let window, let frame = ElementGeometry.frame(of: window) else {
        return false
    }

    if !scoped {
        await glow.activityStarted()
        scoped = true
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
        return true
    }
    return false
}
