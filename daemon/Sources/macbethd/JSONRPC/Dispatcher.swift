import Foundation

/// Routes JSON-RPC method calls to registered handlers.
actor Dispatcher {
    typealias Handler = @Sendable (JSONValue?) async throws -> JSONValue
    typealias ContextualHandler = @Sendable (JSONValue?, String) async throws -> JSONValue
    typealias ConnectionClosedHandler = @Sendable (String) async -> Void

    private var handlers: [String: Handler] = [:]
    private var contextualHandlers: [String: ContextualHandler] = [:]
    private var connectionClosedHandlers: [ConnectionClosedHandler] = []

    func register(method: String, handler: @escaping Handler) {
        handlers[method] = handler
    }

    /// Register a handler that also receives the stable id of the socket
    /// connection which sent the request. This is used for resources whose
    /// lifetime must not outlive a crashed or disconnected client.
    func registerContextual(method: String, handler: @escaping ContextualHandler) {
        contextualHandlers[method] = handler
    }

    func registerConnectionClosed(handler: @escaping ConnectionClosedHandler) {
        connectionClosedHandlers.append(handler)
    }

    /// Look up a handler under actor isolation. Callers invoke it outside the actor
    /// so one slow handler can't stall every other in-flight request.
    func handler(for method: String) -> Handler? {
        handlers[method]
    }

    func contextualHandler(for method: String) -> ContextualHandler? {
        contextualHandlers[method]
    }

    func connectionClosed(_ connectionID: String) async {
        for handler in connectionClosedHandlers {
            await handler(connectionID)
        }
    }

    /// Return every registered RPC method. Used by the MCP demo to prove that
    /// the public tool surface stays in sync with the daemon dispatcher.
    func registeredMethods() -> [String] {
        Set(handlers.keys).union(contextualHandlers.keys).sorted()
    }

    nonisolated func dispatch(
        request: JSONRPCRequest,
        connectionID: String = "anonymous"
    ) async -> JSONRPCResponse {
        guard request.jsonrpc == "2.0" else {
            return JSONRPCResponse(id: request.id, error: .invalidRequest("jsonrpc must be \"2.0\""))
        }

        let contextualHandler = await self.contextualHandler(for: request.method)
        let handler = await self.handler(for: request.method)
        guard contextualHandler != nil || handler != nil else {
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }

        let id = request.id
        let params = request.params
        return await Task.detached(priority: .userInitiated) { () -> JSONRPCResponse in
            do {
                let result: JSONValue
                if let contextualHandler {
                    result = try await contextualHandler(params, connectionID)
                } else {
                    result = try await handler!(params)
                }
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
    /// A handle this daemon issued whose element is gone. Carries the lifecycle reason
    /// so callers can tell a TTL eviction from a destroyed or recycled element.
    case staleHandle(String, handleId: String?, reason: String)
    /// A handle id this daemon never issued.
    case unknownHandle(String, handleId: String?)

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
        case .staleHandle(let msg, let handleId, let reason):
            .staleHandle(msg, data: handleErrorData(handleId: handleId, reason: reason))
        case .unknownHandle(let msg, let handleId):
            .unknownHandle(msg, data: handleErrorData(handleId: handleId, reason: "never_issued"))
        }
    }
}

/// Machine-readable detail for the handle-lifecycle errors, so an agent can branch on
/// `data.reason` instead of parsing prose.
private func handleErrorData(handleId: String?, reason: String) -> JSONValue {
    var data: [String: JSONValue] = ["reason": .string(reason)]
    if let handleId { data["handleId"] = .string(handleId) }
    return .object(data)
}
