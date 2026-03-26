@preconcurrency import ApplicationServices
import Foundation

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

            let tree = await walkTree(
                root: appElement.element,
                pid: conn.pid,
                handleTable: handleTable,
                maxDepth: maxDepth,
                includeInvisible: includeInvisible
            )

            if format == "json" {
                return .object(["tree": serializeTreeAsJSON(tree)])
            } else {
                let text = serializeTreeAsText(tree)
                return .object(["tree": .string(text)])
            }
        }
    }
}
