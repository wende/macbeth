@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// Click strategy ladder.
enum ClickStrategy: String {
    /// AXPress the element (then a pressable parent/child), escalating to the
    /// flash click if AXPress is unavailable or errors. Default.
    case auto
    /// AXPress only; error if the element advertises no press action or it fails.
    case ax
    /// Force the flash-click path (useful when AXPress "succeeds" but is a no-op).
    case flash

    static func parse(_ raw: String?) -> ClickStrategy {
        guard let raw, let s = ClickStrategy(rawValue: raw) else { return .auto }
        return s
    }
}

/// Register the click RPC method.
func registerClick(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable,
    verbose: Bool
) {
    Task {
        await dispatcher.register(method: "click") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'appHandle'")
            }

            let timeout = obj["timeout"]?.numberValue ?? 5.0
            let strategy = ClickStrategy.parse(obj["strategy"]?.stringValue)
            let waitForIdleMs = obj["waitForIdleMs"]?.numberValue ?? 0

            let element = try await resolveTarget(
                obj: obj, appHandle: appHandle,
                appManager: appManager, handleTable: handleTable,
                timeout: timeout
            )

            guard let conn = await appManager.get(appHandle) else {
                throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
            }

            let usedStrategy = try await performClick(
                element: element.element,
                targetPid: conn.pid,
                strategy: strategy,
                waitForIdleMs: waitForIdleMs,
                verbose: verbose
            )

            return .object(["success": .bool(true), "strategy": .string(usedStrategy.rawValue)])
        }
    }
}

/// Execute the click according to the requested strategy. Returns the strategy
/// actually used to reach the target (`ax` or `flash`).
private func performClick(
    element: AXUIElement,
    targetPid: pid_t,
    strategy: ClickStrategy,
    waitForIdleMs: Double,
    verbose: Bool
) async throws -> ClickStrategy {
    switch strategy {
    case .flash:
        try await flashClick(element: element, targetPid: targetPid,
                             waitForIdleMs: waitForIdleMs, verbose: verbose)
        return .flash

    case .ax:
        guard elementActions(element).contains(kAXPressAction as String) else {
            throw RPCError.actionFailed("Click failed: element advertises no AXPress action (strategy: ax)")
        }
        let r = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard r == .success else {
            throw RPCError.actionFailed("Click failed: AXPress returned AXError \(r.rawValue) (strategy: ax)")
        }
        return .ax

    case .auto:
        // AXPress on the element itself.
        if elementActions(element).contains(kAXPressAction as String) {
            let r = AXUIElementPerformAction(element, kAXPressAction as CFString)
            // Success is trusted (no element-level verification in v1).
            if r == .success { return .ax }
            // AXError → escalate to flash.
        } else if let relative = pressableRelative(of: element) {
            // Element lists no press action: try a pressable parent/first child.
            let r = AXUIElementPerformAction(relative, kAXPressAction as CFString)
            if r == .success { return .ax }
        }
        // Escalate: AXPress unavailable or errored.
        try await flashClick(element: element, targetPid: targetPid,
                            waitForIdleMs: waitForIdleMs, verbose: verbose)
        return .flash
    }
}

/// Wrap the flash click, mapping structured `FlashClickError`s to JSON-RPC
/// errors that name the failing phase.
private func flashClick(
    element: AXUIElement,
    targetPid: pid_t,
    waitForIdleMs: Double,
    verbose: Bool
) async throws {
    do {
        try await performFlashClick(
            element: element, targetPid: targetPid,
            waitForIdleMs: waitForIdleMs, verbose: verbose
        )
    } catch let e as FlashClickError {
        throw RPCError.actionFailed(e.message)
    }
}

/// A parent or first child that advertises AXPress — some elements wrap the
/// actionable one (e.g. a group around a button, or a cell holding it).
private func pressableRelative(of element: AXUIElement) -> AXUIElement? {
    let press = kAXPressAction as String

    // Parent first.
    var parentRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
       let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID() {
        let parentEl = parent as! AXUIElement
        if elementActions(parentEl).contains(press) { return parentEl }
    }

    // Then the first child that lists AXPress.
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let children = childrenRef as? [AXUIElement] {
        for child in children where elementActions(child).contains(press) {
            return child
        }
    }
    return nil
}
