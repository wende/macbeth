@preconcurrency import ApplicationServices

/// AXUIElement is thread-safe (mach port wrapper) but not marked Sendable.
/// This wrapper makes it safe to use across concurrency boundaries.
struct SendableElement: @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }
}
