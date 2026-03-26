import Foundation

/// A JSON-RPC 2.0 request ID — either a string or integer.
enum JSONRPCId: Sendable, Equatable, Codable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let n = try? container.decode(Int.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "ID must be string or integer")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }
}

/// A JSON-RPC 2.0 request.
struct JSONRPCRequest: Sendable, Codable {
    let jsonrpc: String
    let method: String
    let params: JSONValue?
    let id: JSONRPCId?

    var isNotification: Bool { id == nil }
}

/// A JSON-RPC 2.0 error object.
struct JSONRPCErrorData: Sendable, Codable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard error codes
    static func parseError(_ msg: String = "Parse error") -> JSONRPCErrorData {
        JSONRPCErrorData(code: -32700, message: msg)
    }

    static func invalidRequest(_ msg: String = "Invalid Request") -> JSONRPCErrorData {
        JSONRPCErrorData(code: -32600, message: msg)
    }

    static func methodNotFound(_ method: String) -> JSONRPCErrorData {
        JSONRPCErrorData(code: -32601, message: "Method not found: \(method)")
    }

    static func invalidParams(_ msg: String = "Invalid params") -> JSONRPCErrorData {
        JSONRPCErrorData(code: -32602, message: msg)
    }

    static func internalError(_ msg: String = "Internal error") -> JSONRPCErrorData {
        JSONRPCErrorData(code: -32603, message: msg)
    }

    // Application-level errors (codes -32000 to -32099)
    static func elementNotFound(_ msg: String = "Element not found") -> JSONRPCErrorData {
        JSONRPCErrorData(code: -32000, message: msg)
    }

    static func timeout(_ msg: String = "Timeout") -> JSONRPCErrorData {
        JSONRPCErrorData(code: -32001, message: msg)
    }

    static func permissionDenied(_ msg: String = "Permission denied") -> JSONRPCErrorData {
        JSONRPCErrorData(code: -32002, message: msg)
    }

    static func appNotFound(_ msg: String = "App not found") -> JSONRPCErrorData {
        JSONRPCErrorData(code: -32003, message: msg)
    }

    static func actionFailed(_ msg: String = "Action failed") -> JSONRPCErrorData {
        JSONRPCErrorData(code: -32004, message: msg)
    }
}

/// A JSON-RPC 2.0 response.
struct JSONRPCResponse: Sendable, Codable {
    let jsonrpc: String
    let result: JSONValue?
    let error: JSONRPCErrorData?
    let id: JSONRPCId?

    init(id: JSONRPCId?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: JSONRPCId?, error: JSONRPCErrorData) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}
