@preconcurrency import ApplicationServices
import Foundation

/// Represents a node in the AX tree.
struct AXNode: Sendable {
    let handleId: String
    let role: String
    let subrole: String?
    let title: String?
    let value: String?
    let identifier: String?
    let label: String?
    let enabled: Bool
    let focused: Bool
    let children: [AXNode]
}

/// Walk the AX element tree starting from a root element.
func walkTree(
    root: AXUIElement,
    pid: pid_t,
    handleTable: HandleTable,
    maxDepth: Int = 10,
    includeInvisible: Bool = false,
    currentDepth: Int = 0
) async -> AXNode {
    let role = getStringAttribute(root, kAXRoleAttribute) ?? "unknown"
    let subrole = getStringAttribute(root, kAXSubroleAttribute)
    let title = getStringAttribute(root, kAXTitleAttribute)
    let value = getValueAsString(root)
    let identifier = getStringAttribute(root, kAXIdentifierAttribute)
    let label = getStringAttribute(root, kAXDescriptionAttribute)
    let enabled = getBoolAttribute(root, kAXEnabledAttribute) ?? true
    let focused = getBoolAttribute(root, kAXFocusedAttribute) ?? false

    let handleId = await handleTable.store(SendableElement(root), pid: pid)

    var childNodes: [AXNode] = []
    if currentDepth < maxDepth {
        let children = getChildren(root)
        for child in children {
            if !includeInvisible && shouldSkipElement(child) {
                // Still recurse into children of skipped elements (pass-through)
                let grandchildren = getChildren(child)
                for grandchild in grandchildren {
                    let node = await walkTree(
                        root: grandchild,
                        pid: pid,
                        handleTable: handleTable,
                        maxDepth: maxDepth,
                        includeInvisible: includeInvisible,
                        currentDepth: currentDepth + 1
                    )
                    childNodes.append(node)
                }
            } else {
                let node = await walkTree(
                    root: child,
                    pid: pid,
                    handleTable: handleTable,
                    maxDepth: maxDepth,
                    includeInvisible: includeInvisible,
                    currentDepth: currentDepth + 1
                )
                childNodes.append(node)
            }
        }
    }

    return AXNode(
        handleId: handleId,
        role: role,
        subrole: subrole,
        title: title,
        value: value,
        identifier: identifier,
        label: label,
        enabled: enabled,
        focused: focused,
        children: childNodes
    )
}

// MARK: - AX attribute helpers

private func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }
    return value as? String
}

private func getBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }
    if let num = value as? NSNumber { return num.boolValue }
    return nil
}

private func getValueAsString(_ element: AXUIElement) -> String? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }

    if let str = value as? String { return str }
    if let num = value as? NSNumber { return num.stringValue }
    return nil
}

private func getChildren(_ element: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref)
    guard result == .success, let children = ref as? [AXUIElement] else { return [] }
    return children
}

/// Determine if an element should be skipped in the filtered tree.
/// Skips decorative/structural-only groups with no title or identifier.
private func shouldSkipElement(_ element: AXUIElement) -> Bool {
    let role = getStringAttribute(element, kAXRoleAttribute) ?? ""

    // Only skip generic group-like roles
    let skippableRoles: Set<String> = [
        "AXGroup", "AXLayoutArea", "AXLayoutItem", "AXSplitGroup",
        "AXScrollArea",
    ]
    guard skippableRoles.contains(role) else { return false }

    // Keep if it has a title or identifier
    if getStringAttribute(element, kAXTitleAttribute) != nil { return false }
    if getStringAttribute(element, kAXIdentifierAttribute) != nil { return false }

    // Keep if it has exactly 0 children (leaf group is likely intentional)
    let children = getChildren(element)
    if children.isEmpty { return false }

    return true
}
