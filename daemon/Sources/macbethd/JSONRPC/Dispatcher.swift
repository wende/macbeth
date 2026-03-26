import Foundation

/// Routes JSON-RPC method calls to registered handlers.
actor Dispatcher {
    typealias Handler = @Sendable (JSONValue?) async throws -> JSONValue

    private var handlers: [String: Handler] = [:]

    func register(method: String, handler: @escaping Handler) {
        handlers[method] = handler
    }

    func dispatch(request: JSONRPCRequest) async -> JSONRPCResponse {
        guard request.jsonrpc == "2.0" else {
            return JSONRPCResponse(id: request.id, error: .invalidRequest("jsonrpc must be \"2.0\""))
        }

        guard let handler = handlers[request.method] else {
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }

        do {
            let result = try await handler(request.params)
            return JSONRPCResponse(id: request.id, result: result)
        } catch let error as RPCError {
            return JSONRPCResponse(id: request.id, error: error.toJSONRPC())
        } catch {
            return JSONRPCResponse(
                id: request.id,
                error: .internalError(error.localizedDescription)
            )
        }
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

    func toJSONRPC() -> JSONRPCErrorData {
        switch self {
        case .invalidParams(let msg): .invalidParams(msg)
        case .elementNotFound(let msg): .elementNotFound(msg)
        case .timeout(let msg): .timeout(msg)
        case .permissionDenied(let msg): .permissionDenied(msg)
        case .appNotFound(let msg): .appNotFound(msg)
        case .actionFailed(let msg): .actionFailed(msg)
        }
    }
}
