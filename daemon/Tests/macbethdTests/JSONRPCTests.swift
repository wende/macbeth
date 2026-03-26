import Testing
import Foundation
@testable import macbethd

@Test func parseRequest() throws {
    let json = """
    {"jsonrpc":"2.0","method":"list_apps","id":1}
    """
    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: json.data(using: .utf8)!)
    #expect(request.jsonrpc == "2.0")
    #expect(request.method == "list_apps")
    #expect(request.id == .number(1))
    #expect(request.params == nil)
}

@Test func parseRequestWithParams() throws {
    let json = """
    {"jsonrpc":"2.0","method":"connect_app","params":{"name":"Finder"},"id":2}
    """
    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: json.data(using: .utf8)!)
    #expect(request.method == "connect_app")
    #expect(request.params?["name"]?.stringValue == "Finder")
    #expect(request.id == .number(2))
}

@Test func parseRequestWithStringId() throws {
    let json = """
    {"jsonrpc":"2.0","method":"test","id":"abc"}
    """
    let request = try JSONDecoder().decode(JSONRPCRequest.self, from: json.data(using: .utf8)!)
    #expect(request.id == .string("abc"))
}

@Test func encodeResponse() throws {
    let response = JSONRPCResponse(id: .number(1), result: .object(["foo": .string("bar")]))
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
    #expect(decoded.jsonrpc == "2.0")
    #expect(decoded.result?["foo"]?.stringValue == "bar")
    #expect(decoded.error == nil)
}

@Test func encodeErrorResponse() throws {
    let response = JSONRPCResponse(id: .number(1), error: .methodNotFound("nope"))
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
    #expect(decoded.error?.code == -32601)
    #expect(decoded.error?.message == "Method not found: nope")
    #expect(decoded.result == nil)
}

@Test func jsonValueRoundTrip() throws {
    let value: JSONValue = .object([
        "string": .string("hello"),
        "number": .number(42),
        "bool": .bool(true),
        "null": .null,
        "array": .array([.number(1), .number(2)]),
        "nested": .object(["a": .string("b")]),
    ])

    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == value)
}
