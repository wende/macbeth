@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import macbethd

@Test func actionTimeoutsAreBounded() {
    #expect(ActionTimeout.clamp(nil) == ActionTimeout.defaultSeconds)
    #expect(ActionTimeout.clamp(-10) == ActionTimeout.minSeconds)
    #expect(ActionTimeout.clamp(120) == 120)
    #expect(ActionTimeout.clamp(10_000) == ActionTimeout.maxSeconds)
    #expect(ActionTimeout.clamp(Double.infinity) == ActionTimeout.defaultSeconds)
}

@Test func sliderFillFailsWhenObservedValueMissesTarget() throws {
    try ensureSliderTargetReached(current: 10, requested: 10, effectiveTarget: 10)

    do {
        try ensureSliderTargetReached(current: 4, requested: 4.7, effectiveTarget: 5)
        Issue.record("missed slider target should have failed")
    } catch let error as RPCError {
        let message = error.toJSONRPC().message
        #expect(message.contains("requested value 4.7"))
        #expect(message.contains("effective integer target 5.0"))
        #expect(message.contains("actual value is 4.0"))
    } catch {
        Issue.record("expected RPCError, got \(error)")
    }
}

@Test func socketCleanupPreservesRegularFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("macbeth-socket-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("important.txt")
    try Data("keep me".utf8).write(to: file)

    #expect(throws: ServerError.self) {
        try removeStaleSocketIfSafe(at: file.path)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep me")
}

@Test func socketCleanupAcceptsAMissingPath() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("macbeth-missing-socket-\(UUID().uuidString)")
    try removeStaleSocketIfSafe(at: missing.path)
}

@Test func socketCleanupPreservesSymlinkAndTarget() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("macbeth-socket-symlink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let target = directory.appendingPathComponent("important.txt")
    let link = directory.appendingPathComponent("macbeth.sock")
    try Data("keep me".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(throws: ServerError.self) {
        try removeStaleSocketIfSafe(at: link.path)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep me")
    #expect(try String(contentsOf: link, encoding: .utf8) == "keep me")
}

@Test func clickHandlerRejectsHandleOwnedByAnotherApp() async {
    let table = HandleTable(ttl: 60)
    let manager = AppConnectionManager(handleTable: table, isProcessAlive: { _ in true })
    let appHandle = "app-a"
    await manager.seedForTesting(AppConnectionManager.Connection(
        pid: 101,
        appElement: SendableElement(AXUIElementCreateSystemWide()),
        bundleId: "com.example.a",
        appName: "App A",
        aliases: [],
        handleId: appHandle,
        runtime: .native,
        manualAccessibilityStatus: "not_attempted",
        webContentReadiness: nil
    ))

    // This is the same handle-table entry a query_tree/get_element call for app B
    // would mint, but avoids depending on live GUI applications in CI.
    let foreignHandle = await table.store(
        SendableElement(AXUIElementCreateSystemWide()),
        pid: 202
    )
    let dispatcher = Dispatcher()
    let glow = GlowIndicator(
        config: .init(enabled: false, color: "#000000", debounceMs: 0, helperPath: nil),
        verbose: false
    )
    registerClick(
        dispatcher: dispatcher,
        appManager: manager,
        handleTable: table,
        glow: glow
    )

    for _ in 0..<100 {
        if await dispatcher.handler(for: "click") != nil { break }
        await Task.yield()
    }
    guard await dispatcher.handler(for: "click") != nil else {
        Issue.record("click handler was not registered")
        return
    }

    let response = await dispatcher.dispatch(request: JSONRPCRequest(
        jsonrpc: "2.0",
        method: "click",
        params: .object([
            "appHandle": .string(appHandle),
            "handleId": .string(foreignHandle),
        ]),
        id: .number(1)
    ))

    #expect(response.error?.code == -32011)
    #expect(response.error?.data?["reason"]?.stringValue == "wrong_app")
    #expect(response.error?.data?["handleId"]?.stringValue == foreignHandle)
}
