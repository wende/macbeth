@preconcurrency import ApplicationServices
import Foundation

/// Register the wait_for RPC method.
func registerWaitFor(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable
) {
    Task {
        await dispatcher.register(method: "wait_for") { params in
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

            let timeout = obj["timeout"]?.numberValue ?? 5.0
            let pollMs = Int(obj["pollMs"]?.numberValue ?? 500)
            let conditionObj = obj["condition"]?.objectValue
            let conditionKind = conditionObj?["kind"]?.stringValue ?? "exists"

            let deadline = Date().addingTimeInterval(timeout)

            switch conditionKind {
            case "exists":
                guard let querySteps = QueryStep.fromArray(obj["query"]) else {
                    throw RPCError.invalidParams("Missing 'query'")
                }
                let path = QueryPath(steps: querySteps)
                while Date() < deadline {
                    if let (element, handleId) = await tryResolveQuery(
                        path: path, root: appElement.element, pid: conn.pid, handleTable: handleTable
                    ) {
                        return elementInfoJSON(element, handleId: handleId)
                    }
                    try await Task.sleep(for: .milliseconds(pollMs))
                }
                let (element, handleId) = try await resolveQuery(
                    path: path, root: appElement.element, pid: conn.pid, handleTable: handleTable
                )
                return elementInfoJSON(element, handleId: handleId)

            case "value_equals":
                let targetValue = conditionObj?["value"]?.stringValue ?? ""
                let element = try await resolveWaitTarget(
                    obj: obj, appElement: appElement, conn: conn, handleTable: handleTable
                )
                while Date() < deadline {
                    let current = getValueAsString(element)
                    if current == targetValue {
                        return .object(["matched": .bool(true), "value": .string(current ?? "")])
                    }
                    try await Task.sleep(for: .milliseconds(pollMs))
                }
                throw RPCError.timeout("Value did not become \"\(targetValue)\" within \(timeout)s")

            case "value_changes":
                let element = try await resolveWaitTarget(
                    obj: obj, appElement: appElement, conn: conn, handleTable: handleTable
                )
                let initialValue = getValueAsString(element)
                while Date() < deadline {
                    let current = getValueAsString(element)
                    if current != initialValue {
                        return .object([
                            "matched": .bool(true),
                            "oldValue": .string(initialValue ?? ""),
                            "newValue": .string(current ?? ""),
                        ])
                    }
                    try await Task.sleep(for: .milliseconds(pollMs))
                }
                throw RPCError.timeout("Value did not change within \(timeout)s")

            case "enabled":
                let element = try await resolveWaitTarget(
                    obj: obj, appElement: appElement, conn: conn, handleTable: handleTable
                )
                while Date() < deadline {
                    let isEnabled = getBoolAttribute(element, kAXEnabledAttribute) ?? false
                    if isEnabled {
                        return .object(["matched": .bool(true), "enabled": .bool(true)])
                    }
                    try await Task.sleep(for: .milliseconds(pollMs))
                }
                throw RPCError.timeout("Element did not become enabled within \(timeout)s")

            default:
                throw RPCError.invalidParams("Unknown condition kind: \(conditionKind)")
            }
        }
    }
}

private func resolveWaitTarget(
    obj: [String: JSONValue],
    appElement: SendableElement,
    conn: AppConnectionManager.Connection,
    handleTable: HandleTable
) async throws -> AXUIElement {
    if let handleId = obj["handleId"]?.stringValue {
        return try await resolveLiveHandle(handleId, in: handleTable).element
    }

    guard let querySteps = QueryStep.fromArray(obj["query"]) else {
        throw RPCError.invalidParams("Missing 'query' or 'handleId'")
    }

    let path = QueryPath(steps: querySteps)
    let (element, _) = try await resolveQuery(
        path: path, root: appElement.element, pid: conn.pid, handleTable: handleTable
    )
    return element
}

// MARK: - Shared target resolution with auto-wait

/// Resolve an action target from either a handleId or query with auto-wait.
func resolveTarget(
    obj: [String: JSONValue],
    appHandle: String,
    appManager: AppConnectionManager,
    handleTable: HandleTable,
    timeout: Double
) async throws -> SendableElement {
    // Direct handle resolution (no wait)
    if let handleId = obj["handleId"]?.stringValue {
        return try await resolveLiveHandle(handleId, in: handleTable)
    }

    // Query-based resolution with auto-wait
    guard let querySteps = QueryStep.fromArray(obj["query"]) else {
        throw RPCError.invalidParams("Missing 'query' or 'handleId'")
    }

    guard let appElement = await appManager.getElement(appHandle) else {
        throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
    }

    guard let conn = await appManager.get(appHandle) else {
        throw RPCError.appNotFound("Invalid app handle: \(appHandle)")
    }

    let path = QueryPath(steps: querySteps)
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if let (element, _) = await tryResolveQuery(
            path: path, root: appElement.element, pid: conn.pid, handleTable: handleTable
        ) {
            return SendableElement(element)
        }
        try await Task.sleep(for: .milliseconds(500))
    }

    // Final attempt — let the detailed error propagate
    let (element, _) = try await resolveQuery(
        path: path, root: appElement.element, pid: conn.pid, handleTable: handleTable
    )
    return SendableElement(element)
}
