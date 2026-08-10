@preconcurrency import ApplicationServices
import Foundation

/// Parse the `maxNodes` JSON value into a `NodeBudget`. Returns nil when no
/// budget applies (omitted or JSON null). Floats and sub-1 values throw.
func parseMaxNodes(_ raw: JSONValue?) throws -> NodeBudget? {
    guard let raw else { return nil }
    if case .null = raw { return nil }
    guard let n = raw.numberValue else {
        throw RPCError.invalidParams(
            "maxNodes must be a positive integer when provided")
    }
    let value = Int(n)
    // Reject non-integers up front: intValue does `Int(n)` and silently
    // truncates 1.5 → 1, so without this guard the daemon would enforce a
    // value the caller never asked for.
    guard n.truncatingRemainder(dividingBy: 1) == 0,
          value >= 1 else {
        throw RPCError.invalidParams(
            "maxNodes must be a positive integer when provided")
    }
    return NodeBudget(value)
}

/// Register the query_tree RPC method.
func registerQueryTree(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable
) {
    Task {
        await dispatcher.register(method: "query_tree") { params in
            guard let obj = params?.objectValue,
                  let appHandle = obj["appHandle"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'appHandle'")
            }

            guard let appElement = await appManager.getElement(appHandle) else {
                throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
            }

            guard let conn = await appManager.get(appHandle) else {
                throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
            }

            let maxDepth = obj["maxDepth"]?.intValue ?? 5
            let format = obj["format"]?.stringValue ?? "text"
            let includeInvisible = obj["includeInvisible"]?.boolValue ?? false

            var budget: NodeBudget? = nil
            if let raw = obj["maxNodes"] {
                budget = try parseMaxNodes(raw)
            }

            let tree = await walkTree(
                root: appElement.element,
                pid: conn.pid,
                handleTable: handleTable,
                maxDepth: maxDepth,
                includeInvisible: includeInvisible,
                budget: budget
            )

            let webContent = inspectWebContent(appElement.element)
            var diagnostics: [String: JSONValue] = [
                "runtime": .string(conn.runtime.rawValue),
                "webContent": .string(webContent.rawValue),
            ]
            if conn.runtime == .electron, webContent != .ready {
                let detail = webContent == .emptyWebArea
                    ? "The app exposes an AXWebArea but no inspectable descendants."
                    : "The app does not currently expose an AXWebArea."
                diagnostics["warning"] = .string(
                    detail
                    + " Retry after the view finishes loading; if it remains degraded, "
                    + "use extract_text, screenshot, menus, or keyboard automation."
                )
            }

            if format == "json" {
                return .object([
                    "tree": serializeTreeAsJSON(tree),
                    "diagnostics": .object(diagnostics),
                ])
            } else {
                let text = serializeTreeAsText(tree)
                return .object([
                    "tree": .string(text),
                    "diagnostics": .object(diagnostics),
                ])
            }
        }
    }
}
