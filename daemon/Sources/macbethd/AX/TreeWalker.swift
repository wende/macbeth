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
    /// Approximate count of descendants the walker skipped because a `maxNodes`
    /// budget ran out. nil means the subtree was walked to completion.
    let truncatedChildren: Int?
}

/// Call-local budget that bounds the number of *visible* (non-skipped) nodes
/// the walker emits. Sequential DFS only — passing this across concurrent
/// walks would race. Hard-code that constraint in any future fan-out change.
final class NodeBudget: @unchecked Sendable {
    private var remaining: Int
    init(_ maxNodes: Int) { self.remaining = maxNodes }
    /// Try to reserve a node slot. Returns true while budget remains. The caller
    /// (the parent of a not-yet-minted child, or the walker itself for the root)
    /// mints exactly one node per accepted call. Does not go negative.
    func tryConsume() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
    var isExhausted: Bool { remaining <= 0 }
}

/// Walk the AX element tree starting from a root element.
///
/// Budget semantics:
///   * The walker always mints a handle for the node it was called on, *before*
///     descending (preserving the canonical "every visible node gets a handle"
///     invariant).
///   * When `budget` is non-nil, the walker consumes one slot at entry, and
///     each child consumes one more from the parent's loop. Skip-pass-through
///     elements (no title/identifier anonymous groups) cost nothing — they
///     emit no `AXNode` and mint no handle.
///   * When the budget runs out, the parent sets `truncatedChildren` to a
///     cheap estimate of remaining visible descendants so the model can
///     re-query the parent's handle to drill deeper.
func walkTree(
    root: AXUIElement,
    pid: pid_t,
    handleTable: HandleTable,
    maxDepth: Int = 10,
    includeInvisible: Bool = false,
    currentDepth: Int = 0,
    budget: NodeBudget? = nil
) async -> AXNode {
    // Root consumes its own slot before we read any children. If the caller
    // set maxNodes=1, the root is the only node and the marker covers every
    // descendant.
    let rootHasSlot = (budget?.tryConsume() ?? true)

    let rawRole = getStringAttribute(root, kAXRoleAttribute)
    let role = rawRole ?? "unknown"
    let subrole = getStringAttribute(root, kAXSubroleAttribute)
    let title = getStringAttribute(root, kAXTitleAttribute)
    let value = getValueAsString(root)
    let identifier = getStringAttribute(root, kAXIdentifierAttribute)
    let label = getStringAttribute(root, kAXDescriptionAttribute)
    let enabled = getBoolAttribute(root, kAXEnabledAttribute) ?? true
    let focused = getBoolAttribute(root, kAXFocusedAttribute) ?? false

    let handleId = await handleTable.store(
        SendableElement(root),
        pid: pid,
        fingerprint: ElementFingerprint(role: rawRole, subrole: subrole, identifier: identifier)
    )

    var childNodes: [AXNode] = []
    var truncated: Int? = nil

    if !rootHasSlot {
        let visible = expandPassThrough(getChildren(root), includeInvisible: includeInvisible)
        truncated = visible.count
    } else if currentDepth < maxDepth {
        let visibleChildren = expandPassThrough(getChildren(root), includeInvisible: includeInvisible)
        var remainingForEstimate = visibleChildren.count

        for child in visibleChildren {
            if let budget, budget.isExhausted {
                truncated = remainingForEstimate
                break
            }
            remainingForEstimate -= 1
            let node = await walkTree(
                root: child,
                pid: pid,
                handleTable: handleTable,
                maxDepth: maxDepth,
                includeInvisible: includeInvisible,
                currentDepth: currentDepth + 1,
                budget: budget
            )
            childNodes.append(node)
            if let childTruncated = node.truncatedChildren {
                truncated = remainingForEstimate + childTruncated
                break
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
        children: childNodes,
        truncatedChildren: truncated
    )
}

// MARK: - AX attribute helpers

func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }
    return value as? String
}

func getBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }
    if let num = value as? NSNumber { return num.boolValue }
    return nil
}

func getValueAsString(_ element: AXUIElement) -> String? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref)
    guard result == .success, let value = ref else { return nil }

    if let str = value as? String { return str }
    if let num = value as? NSNumber { return num.stringValue }
    return nil
}

func getChildren(_ element: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref)
    guard result == .success, let children = ref as? [AXUIElement] else { return [] }
    return children
}

/// Flatten `shouldSkipElement` containers so the walker descends through them
/// without minting them as nodes or charging them against the budget. Skipped
/// containers usually hold leaf content the model still needs to discover.
///
/// - `includeInvisible == true` returns the input untouched.
/// - Otherwise, recurse one level past each skipped child to surface its
///   descendants; children that themselves are skipped get expanded again.
@inline(__always)
func expandPassThrough(
    _ elements: [AXUIElement],
    includeInvisible: Bool
) -> [AXUIElement] {
    guard !includeInvisible else { return elements }
    var result: [AXUIElement] = []
    result.reserveCapacity(elements.count)
    for element in elements {
        if shouldSkipElement(element) {
            let grandChildren = getChildren(element)
            if grandChildren.isEmpty {
                // No grandchildren — keep the original element so it isn't lost.
                // Emitting a would-be-skipped node here is consistent with the
                // previous behaviour (the container was omitted, but its content
                // was kept); with no content to keep, this branch should not
                // fire because shouldSkipElement already returns false for
                // 0-child groups.
                continue
            }
            result.append(contentsOf: expandPassThrough(grandChildren, includeInvisible: false))
        } else {
            result.append(element)
        }
    }
    return result
}

/// Determine if an element should be skipped in the filtered tree.
/// Skips decorative/structural-only groups with no title or identifier.
func shouldSkipElement(_ element: AXUIElement) -> Bool {
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
