@preconcurrency import ApplicationServices
import Foundation

/// Register the get_element RPC method.
func registerGetElement(
    dispatcher: Dispatcher,
    appManager: AppConnectionManager,
    handleTable: HandleTable
) {
    Task {
        await dispatcher.register(method: "get_element") { params in
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

            if let handleId = obj["handleId"]?.stringValue {
                guard let resolved = await handleTable.resolve(handleId) else {
                    throw RPCError.elementNotFound("Handle expired: \(handleId)")
                }
                return elementInfoJSON(resolved.element, handleId: handleId)
            }

            guard let querySteps = QueryStep.fromArray(obj["query"]) else {
                throw RPCError.invalidParams("Missing 'query' or 'handleId'")
            }

            let path = QueryPath(steps: querySteps)
            let (element, handleId) = try await resolveQuery(
                path: path, root: appElement.element, pid: conn.pid, handleTable: handleTable
            )

            return elementInfoJSON(element, handleId: handleId)
        }
    }
}
