@preconcurrency import ApplicationServices
import Foundation

/// A single step in a query path.
struct QueryStep: Sendable {
    let role: String?
    let title: String?
    let identifier: String?
    let titlePattern: String?
    let index: Int?

    /// Parse a QueryStep from a JSON params object.
    static func from(_ json: JSONValue) -> QueryStep? {
        guard case .object(let obj) = json else { return nil }
        return QueryStep(
            role: obj["role"]?.stringValue,
            title: obj["title"]?.stringValue,
            identifier: obj["identifier"]?.stringValue,
            titlePattern: obj["titlePattern"]?.stringValue,
            index: obj["index"]?.intValue
        )
    }

    /// Parse an array of QuerySteps from JSON.
    static func fromArray(_ json: JSONValue?) -> [QueryStep]? {
        guard let arr = json?.arrayValue else { return nil }
        return arr.compactMap { QueryStep.from($0) }
    }
}

/// A query path is an array of steps, resolved left-to-right down the tree.
struct QueryPath: Sendable {
    let steps: [QueryStep]
}

/// Resolve a query path against the AX tree, returning the matching element and its handle.
/// Each step searches all descendants recursively (like Playwright's locators).
func resolveQuery(
    path: QueryPath,
    root: AXUIElement,
    pid: pid_t,
    handleTable: HandleTable
) async throws -> (AXUIElement, String) {
    var current = root

    for (i, step) in path.steps.enumerated() {
        let matches = findDescendants(current, matching: step)

        let targetIndex = step.index ?? 0
        guard targetIndex < matches.count else {
            let stepDesc = describeStep(step)
            let hint = buildHint(parent: current, failedStep: step)
            throw RPCError.elementNotFound(
                "No element matching \(stepDesc) at step \(i + 1) (found \(matches.count) matches, wanted index \(targetIndex))\(hint)"
            )
        }

        current = matches[targetIndex]
    }

    let handleId = await handleTable.store(SendableElement(current), pid: pid)
    return (current, handleId)
}

/// Try to resolve a query, returning nil instead of throwing if not found.
func tryResolveQuery(
    path: QueryPath,
    root: AXUIElement,
    pid: pid_t,
    handleTable: HandleTable
) async -> (AXUIElement, String)? {
    try? await resolveQuery(path: path, root: root, pid: pid, handleTable: handleTable)
}

// MARK: - Error hints

/// Build a helpful hint showing what's available when a query step fails.
private func buildHint(parent: AXUIElement, failedStep: QueryStep) -> String {
    struct ElementSummary {
        let title: String?
        let identifier: String?
        let label: String?
        let value: String?
        let subrole: String?
    }

    var sameRole: [ElementSummary] = []
    var availableRoles: [String: Int] = [:]

    let targetRole = failedStep.role.map { axRoleName($0) }

    // BFS with a cap to avoid traversing enormous trees
    var queue: [AXUIElement] = [parent]
    var visited = 0
    let maxVisit = 500

    while !queue.isEmpty && visited < maxVisit {
        let element = queue.removeFirst()
        visited += 1

        let children = getChildElements(element)
        for child in children {
            let role = getStringAttr(child, kAXRoleAttribute) ?? ""

            if let targetRole, (role == targetRole || role == failedStep.role) {
                if sameRole.count < 10 {
                    sameRole.append(ElementSummary(
                        title: getStringAttr(child, kAXTitleAttribute),
                        identifier: getStringAttr(child, kAXIdentifierAttribute),
                        label: getStringAttr(child, kAXDescriptionAttribute),
                        value: {
                            var ref: CFTypeRef?
                            let r = AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &ref)
                            guard r == .success else { return nil }
                            if let s = ref as? String { return s.count > 40 ? String(s.prefix(40)) + "..." : s }
                            if let n = ref as? NSNumber { return n.stringValue }
                            return nil
                        }(),
                        subrole: getStringAttr(child, kAXSubroleAttribute)
                    ))
                }
            } else {
                availableRoles[role, default: 0] += 1
            }

            queue.append(child)
        }
    }

    var lines: [String] = []

    if !sameRole.isEmpty {
        let roleLabel = failedStep.role ?? "?"
        lines.append("  Available \(roleLabel) elements:")
        for el in sameRole {
            var parts: [String] = []
            if let t = el.title { parts.append("\"\(t)\"") }
            if let id = el.identifier { parts.append("id:\"\(id)\"") }
            if let l = el.label { parts.append("label:\"\(l)\"") }
            if let v = el.value { parts.append("value:\"\(v)\"") }
            if let s = el.subrole { parts.append("subrole:\(s)") }
            lines.append("    - " + (parts.isEmpty ? "(no attributes)" : parts.joined(separator: " ")))
        }
    } else {
        // No same-role elements found — show what roles exist
        let sorted = availableRoles.sorted { $0.value > $1.value }.prefix(8)
        if !sorted.isEmpty {
            lines.append("  No \(failedStep.role ?? "matching") elements found. Available roles:")
            for (role, count) in sorted {
                lines.append("    - \(role) (\(count))")
            }
        }
    }

    if visited >= maxVisit {
        lines.append("  (searched \(maxVisit) elements, tree may contain more)")
    }

    return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
}

// MARK: - Recursive descent

/// BFS through all descendants, returning elements that match the step.
/// This lets query paths skip intermediate containers (like Playwright's locators).
private func findDescendants(_ root: AXUIElement, matching step: QueryStep, maxDepth: Int = 50) -> [AXUIElement] {
    var matches: [AXUIElement] = []
    var queue: [(AXUIElement, Int)] = [(root, 0)]

    while !queue.isEmpty {
        let (element, depth) = queue.removeFirst()
        guard depth <= maxDepth else { continue }

        let children = getChildElements(element)
        for child in children {
            if matchesStep(child, step) {
                matches.append(child)
                // Don't recurse into matched elements — a match scopes
                // the subtree for the next query step.
            } else {
                queue.append((child, depth + 1))
            }
        }
    }

    return matches
}

// MARK: - Matching

private func matchesStep(_ element: AXUIElement, _ step: QueryStep) -> Bool {
    // Role match
    if let role = step.role {
        let elementRole = getStringAttr(element, kAXRoleAttribute) ?? ""
        let normalizedRole = axRoleName(role)
        if elementRole != normalizedRole && elementRole != role {
            return false
        }
    }

    // Title match
    if let title = step.title {
        let elementTitle = getStringAttr(element, kAXTitleAttribute) ?? ""
        if elementTitle != title {
            return false
        }
    }

    // Identifier match
    if let identifier = step.identifier {
        let elementId = getStringAttr(element, kAXIdentifierAttribute) ?? ""
        if elementId != identifier {
            return false
        }
    }

    // Title pattern match (regex)
    if let pattern = step.titlePattern {
        let elementTitle = getStringAttr(element, kAXTitleAttribute) ?? ""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(elementTitle.startIndex..., in: elementTitle)
        if regex.firstMatch(in: elementTitle, range: range) == nil {
            return false
        }
    }

    return true
}

// MARK: - AX helpers (local to this file)

private func getStringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    guard result == .success, let value = ref as? String else { return nil }
    return value
}

/// Get the visible children of an element, skipping through anonymous structural
/// containers (same logic as TreeWalker.shouldSkipElement) so that query paths
/// match the flattened tree shown by query_tree.
private func getVisibleChildren(_ element: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    for child in getChildElements(element) {
        if shouldSkipQueryElement(child) {
            result.append(contentsOf: getVisibleChildren(child))
        } else {
            result.append(child)
        }
    }
    return result
}

/// Mirror of TreeWalker's shouldSkipElement — skips anonymous group-like
/// containers that have no title or identifier and have children.
private func shouldSkipQueryElement(_ element: AXUIElement) -> Bool {
    let role = getStringAttr(element, kAXRoleAttribute) ?? ""
    let skippableRoles: Set<String> = [
        "AXGroup", "AXLayoutArea", "AXLayoutItem", "AXSplitGroup",
        "AXScrollArea",
    ]
    guard skippableRoles.contains(role) else { return false }
    if getStringAttr(element, kAXTitleAttribute) != nil { return false }
    if getStringAttr(element, kAXIdentifierAttribute) != nil { return false }
    let children = getChildElements(element)
    if children.isEmpty { return false }
    return true
}

private func getChildElements(_ element: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref)
    guard result == .success, let children = ref as? [AXUIElement] else { return [] }
    return children
}

private func describeStep(_ step: QueryStep) -> String {
    var parts: [String] = []
    if let role = step.role { parts.append("role=\(role)") }
    if let title = step.title { parts.append("title=\"\(title)\"") }
    if let id = step.identifier { parts.append("id=\"\(id)\"") }
    if let pattern = step.titlePattern { parts.append("titlePattern=\"\(pattern)\"") }
    return "{" + parts.joined(separator: ", ") + "}"
}

/// Get element info as a JSONValue.
func elementInfoJSON(_ element: AXUIElement, handleId: String) -> JSONValue {
    let role = getStringAttr(element, kAXRoleAttribute) ?? "unknown"
    let title = getStringAttr(element, kAXTitleAttribute)
    let identifier = getStringAttr(element, kAXIdentifierAttribute)
    let label = getStringAttr(element, kAXDescriptionAttribute)

    var valueRef: CFTypeRef?
    let _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
    let value: String? = {
        if let v = valueRef as? String { return v }
        if let n = valueRef as? NSNumber { return n.stringValue }
        return nil
    }()

    var enabledRef: CFTypeRef?
    let _ = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef)
    let enabled = (enabledRef as? NSNumber)?.boolValue ?? true

    var focusedRef: CFTypeRef?
    let _ = AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedRef)
    let focused = (focusedRef as? NSNumber)?.boolValue ?? false

    var obj: [String: JSONValue] = [
        "handleId": .string(handleId),
        "role": .string(role),
        "enabled": .bool(enabled),
        "focused": .bool(focused),
    ]
    if let title { obj["title"] = .string(title) }
    if let value { obj["value"] = .string(value) }
    if let identifier { obj["identifier"] = .string(identifier) }
    if let label { obj["label"] = .string(label) }

    return .object(obj)
}

/// Dump all attribute names and their string values for debugging.
func dumpAttributes(_ element: AXUIElement) -> [String: JSONValue] {
    var namesRef: CFArray?
    let result = AXUIElementCopyAttributeNames(element, &namesRef)
    guard result == .success, let names = namesRef as? [String] else { return [:] }

    var attrs: [String: JSONValue] = [:]
    for name in names {
        var ref: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(element, name as CFString, &ref)
        guard copyResult == .success, let val = ref else {
            attrs[name] = .null
            continue
        }
        if let s = val as? String {
            attrs[name] = .string(s)
        } else if let n = val as? NSNumber {
            attrs[name] = .number(n.doubleValue)
        } else if let b = val as? Bool {
            attrs[name] = .bool(b)
        } else {
            attrs[name] = .string(String(describing: val))
        }
    }
    return attrs
}
