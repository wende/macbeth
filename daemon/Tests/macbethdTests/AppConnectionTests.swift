import Testing
import Foundation
@preconcurrency import ApplicationServices
@testable import macbethd

/// Mutable set of "live" pids, standing in for the NSRunningApplication liveness probe.
private final class FakeProcessTable: @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Set<pid_t>

    init(alive: Set<pid_t>) {
        self.alive = alive
    }

    func terminate(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        alive.remove(pid)
    }

    func isAlive(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive.contains(pid)
    }
}

private func makeConnection(pid: pid_t, handleId: String) -> AppConnectionManager.Connection {
    AppConnectionManager.Connection(
        pid: pid,
        appElement: SendableElement(AXUIElementCreateSystemWide()),
        bundleId: "com.example.app\(pid)",
        appName: "App \(pid)",
        aliases: [],
        handleId: handleId,
        runtime: .native,
        manualAccessibilityStatus: "not_attempted",
        webContentReadiness: nil
    )
}

/// Seeds two connections and returns the manager plus its fake process table.
private func makeManager(
    alive: Set<pid_t>,
    handleTable: HandleTable
) async -> (AppConnectionManager, FakeProcessTable) {
    let processes = FakeProcessTable(alive: alive)
    let manager = AppConnectionManager(
        handleTable: handleTable,
        isProcessAlive: { processes.isAlive($0) }
    )
    return (manager, processes)
}

@Test func evictsConnectionsForTerminatedApps() async {
    let table = HandleTable(ttl: 60)
    let (manager, processes) = await makeManager(alive: [101, 202], handleTable: table)

    await manager.seedForTesting(makeConnection(pid: 101, handleId: "h_0"))
    await manager.seedForTesting(makeConnection(pid: 202, handleId: "h_1"))
    #expect(await manager.connectionCount == 2)

    processes.terminate(101)
    await manager.evictTerminatedApps()

    #expect(await manager.connectionCount == 1)
    #expect(await manager.get("h_0") == nil)
    #expect(await manager.get("h_1") != nil)
}

@Test func evictionDropsHandlesOwnedByTheDeadApp() async {
    let table = HandleTable(ttl: 60)
    let (manager, processes) = await makeManager(alive: [101, 202], handleTable: table)

    await manager.seedForTesting(makeConnection(pid: 101, handleId: "h_0"))
    await manager.seedForTesting(makeConnection(pid: 202, handleId: "h_1"))

    // Handles minted against each app by a tree walk.
    let element = SendableElement(AXUIElementCreateSystemWide())
    _ = await table.store(element, pid: 101)
    _ = await table.store(element, pid: 101)
    let survivor = await table.store(element, pid: 202)
    #expect(await table.count == 3)

    processes.terminate(101)
    await manager.evictTerminatedApps()

    #expect(await table.count == 1)
    #expect(await table.resolve(survivor) != nil)
}

@Test func evictionLeavesLiveConnectionsAlone() async {
    let table = HandleTable(ttl: 60)
    let (manager, _) = await makeManager(alive: [101, 202], handleTable: table)

    await manager.seedForTesting(makeConnection(pid: 101, handleId: "h_0"))
    await manager.seedForTesting(makeConnection(pid: 202, handleId: "h_1"))

    await manager.evictTerminatedApps()

    #expect(await manager.connectionCount == 2)
}

@Test func evictionIsSafeWithNoConnections() async {
    let table = HandleTable(ttl: 60)
    let (manager, _) = await makeManager(alive: [], handleTable: table)

    await manager.evictTerminatedApps()

    #expect(await manager.connectionCount == 0)
}
