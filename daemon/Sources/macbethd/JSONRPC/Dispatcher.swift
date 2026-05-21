import Foundation

/// Routes JSON-RPC method calls to registered handlers.
actor Dispatcher {
    typealias Handler = @Sendable (JSONValue?) async throws -> JSONValue

    private var handlers: [String: Handler] = [:]

    func register(method: String, handler: @escaping Handler) {
        handlers[method] = handler
    }

    /// Look up a handler under actor isolation. Callers invoke it outside the actor
    /// so one slow handler can't stall every other in-flight request.
    func handler(for method: String) -> Handler? {
        handlers[method]
    }

    nonisolated func dispatch(request: JSONRPCRequest) async -> JSONRPCResponse {
        guard request.jsonrpc == "2.0" else {
            return JSONRPCResponse(id: request.id, error: .invalidRequest("jsonrpc must be \"2.0\""))
        }

        guard let handler = await self.handler(for: request.method) else {
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }

        let id = request.id
        let params = request.params
        return await Task.detached(priority: .userInitiated) { () -> JSONRPCResponse in
            do {
                let result = try await handler(params)
                return JSONRPCResponse(id: id, result: result)
            } catch let error as RPCError {
                return JSONRPCResponse(id: id, error: error.toJSONRPC())
            } catch {
                return JSONRPCResponse(
                    id: id,
                    error: .internalError(error.localizedDescription)
                )
            }
        }.value
    }
}

/// Typed errors that RPC handlers can throw.
enum RPCError: Error {
    case invalidParams(String)
    case elementNotFound(String)
    case timeout(String)
    case permissionDenied(String)
    case appNotFound(String)
    case actionFailed(String)
    case menuItemNotFound(String)
    case menuItemDisabled(String)
    case appBusy(String)
    case scriptFailed(String, data: JSONValue? = nil)
    case axLookupFailed(String)

    func toJSONRPC() -> JSONRPCErrorData {
        switch self {
        case .invalidParams(let msg): .invalidParams(msg)
        case .elementNotFound(let msg): .elementNotFound(msg)
        case .timeout(let msg): .timeout(msg)
        case .permissionDenied(let msg): .permissionDenied(msg)
        case .appNotFound(let msg): .appNotFound(msg)
        case .actionFailed(let msg): .actionFailed(msg)
        case .menuItemNotFound(let msg): .menuItemNotFound(msg)
        case .menuItemDisabled(let msg): .menuItemDisabled(msg)
        case .appBusy(let msg): .appBusy(msg)
        case .scriptFailed(let msg, let data): .scriptFailed(msg, data: data)
        case .axLookupFailed(let msg): .axLookupFailed(msg)
        }
    }
}
