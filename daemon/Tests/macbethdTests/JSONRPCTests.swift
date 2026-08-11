import Testing
import Foundation
@testable import macbethd

private actor ConnectionProbe {
    private(set) var dispatchedID: String?
    private(set) var closedIDs: [String] = []

    func dispatched(_ id: String) { dispatchedID = id }
    func closed(_ id: String) { closedIDs.append(id) }
}

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

@Test func dispatcherReportsRegisteredMethodsInStableOrder() async {
    let dispatcher = Dispatcher()
    await dispatcher.register(method: "zeta") { _ in .null }
    await dispatcher.register(method: "alpha") { _ in .null }
    await dispatcher.registerContextual(method: "contextual") { _, _ in .null }

    #expect(await dispatcher.registeredMethods() == ["alpha", "contextual", "zeta"])
}

@Test func dispatcherPassesConnectionIdentityAndReportsDisconnect() async {
    let dispatcher = Dispatcher()
    let probe = ConnectionProbe()
    await dispatcher.registerContextual(method: "owned") { _, connectionID in
        await probe.dispatched(connectionID)
        return .string(connectionID)
    }
    await dispatcher.registerConnectionClosed { connectionID in
        await probe.closed(connectionID)
    }

    let request = JSONRPCRequest(jsonrpc: "2.0", method: "owned", params: nil, id: .number(1))
    let response = await dispatcher.dispatch(request: request, connectionID: "client-42")
    await dispatcher.connectionClosed("client-42")

    #expect(response.result?.stringValue == "client-42")
    #expect(await probe.dispatchedID == "client-42")
    #expect(await probe.closedIDs == ["client-42"])
}

// Socket-level integration is verified end-to-end in the manual smoke tests
// (build the daemon, run a client, inspect `~/Library/Caches/macbeth/logs/`).
// The daemon test suite has no other socket-level tests because the Swift
// Testing framework's task lifecycle races with `Task.detached` server loops
// in ways that make deterministic timing hard. Logger behaviour itself is
// covered by `RequestLoggerTests`; the wiring (`emitLog` → `RequestLogger.log`)
// is a one-line call site that gets exercised every time anyone hits the daemon.
