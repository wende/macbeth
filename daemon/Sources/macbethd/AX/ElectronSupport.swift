@preconcurrency import ApplicationServices
import Foundation

/// The Chromium/Electron attribute that opts an app's renderer into building a full
/// accessibility tree for third-party assistive-technology clients.
private let kAXManualAccessibility = "AXManualAccessibility"

/// Enable Chromium's accessibility tree for an Electron app.
///
/// We deliberately do NOT set `AXEnhancedUserInterface` — in Electron apps it triggers
/// window resize/reposition bugs. `AXManualAccessibility` is the documented, side-effect-free
/// switch for turning on the web-content tree.
func enableManualAccessibility(_ appElement: AXUIElement) -> AXError {
    let result = AXUIElementSetAttributeValue(
        appElement, kAXManualAccessibility as CFString, kCFBooleanTrue
    )
    // Non-Electron apps don't recognise the attribute; that's expected, so we ignore
    // the error for control flow but surface it under verbose logging.
    if result != .success {
        vlog("AXManualAccessibility not accepted (error: \(result.rawValue)) — expected for non-Electron apps")
    } else {
        vlog("AXManualAccessibility enabled")
    }
    return result
}

enum WebContentReadiness: String, Sendable {
    case ready
    case emptyWebArea = "empty_web_area"
    case noWebArea = "no_web_area"
}

/// Poll the app's tree until an `AXWebArea` appears (Chromium finished building the tree)
/// or the timeout expires. Proceeds regardless — some Electron windows legitimately have
/// no web content in the front window, and native fallback behaviour must be preserved.
///
/// Takes a `SendableElement` so it can be awaited across the actor boundary in `connect`
/// without tripping Swift 6 strict-concurrency checks on the non-Sendable `AXUIElement`.
func waitForWebContent(_ app: SendableElement, timeout: TimeInterval) async -> WebContentReadiness {
    guard timeout > 0 else { return inspectWebContent(app.element) }
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        let state = inspectWebContent(app.element)
        if state == .ready {
            vlog("Electron web content ready (AXWebArea descendants found)")
            return state
        }
        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            return state
        }
    }

    let state = inspectWebContent(app.element)
    vlog("Electron web content not ready after \(timeout)s (\(state.rawValue)) — proceeding with degraded AX output")
    return state
}

/// Cheap, shallow inspection for an `AXWebArea` anywhere within the app's windows.
/// Bounded in both depth and total nodes visited so it stays fast on large trees.
func inspectWebContent(
    _ appElement: AXUIElement,
    maxDepth: Int = 8,
    maxVisit: Int = 400
) -> WebContentReadiness {
    var queue: [(AXUIElement, Int)] = [(appElement, 0)]
    var visited = 0
    var foundWebArea = false

    while !queue.isEmpty && visited < maxVisit {
        let (element, depth) = queue.removeFirst()
        visited += 1

        if depth > 0 {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
               (roleRef as? String) == (kAXWebAreaRole as String) {
                foundWebArea = true
                if !getChildren(element).isEmpty {
                    return .ready
                }
            }
        }

        guard depth < maxDepth else { continue }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                queue.append((child, depth + 1))
            }
        }
    }

    return foundWebArea ? .emptyWebArea : .noWebArea
}

private let kAXWebAreaRole = "AXWebArea"
