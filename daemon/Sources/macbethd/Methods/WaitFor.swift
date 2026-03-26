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

            guard let querySteps = QueryStep.fromArray(obj["query"]) else {
                throw RPCError.invalidParams("Missing 'query'")
            }

            let timeout = obj["timeout"]?.numberValue ?? 30.0
            let path = QueryPath(steps: querySteps)

            let deadline = Date().addingTimeInterval(timeout)

            while Date() < deadline {
                if let (element, handleId) = await tryResolveQuery(
                    path: path, root: appElement.element, pid: conn.pid, handleTable: handleTable
                ) {
                    return elementInfoJSON(element, handleId: handleId)
                }
                try await Task.sleep(for: .milliseconds(500))
            }

            throw RPCError.timeout("Element not found within \(timeout)s")
        }
    }
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
        guard let resolved = await handleTable.resolve(handleId) else {
            throw RPCError.elementNotFound("Handle expired: \(handleId)")
        }
        return resolved
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

    throw RPCError.timeout("Element not found within \(timeout)s")
}
