import Testing
import Foundation
@preconcurrency import ApplicationServices
@testable import macbethd

@Test func storeAndResolve() async {
    let table = HandleTable(ttl: 60)
    let element = AXUIElementCreateSystemWide()
    let handleId = await table.store(SendableElement(element), pid: 1)
    #expect(handleId == "h_0")

    let resolved = await table.resolve(handleId)
    #expect(resolved != nil)
}

@Test func sequentialIds() async {
    let table = HandleTable(ttl: 60)
    let element = AXUIElementCreateSystemWide()
    let id1 = await table.store(SendableElement(element), pid: 1)
    let id2 = await table.store(SendableElement(element), pid: 1)
    let id3 = await table.store(SendableElement(element), pid: 1)
    #expect(id1 == "h_0")
    #expect(id2 == "h_1")
    #expect(id3 == "h_2")
}

@Test func resolveNonexistent() async {
    let table = HandleTable(ttl: 60)
    let resolved = await table.resolve("h_999")
    #expect(resolved == nil)
}

@Test func expireStale() async {
    let table = HandleTable(ttl: 0)  // 0 TTL = immediate expiration
    let element = AXUIElementCreateSystemWide()
    let handleId = await table.store(SendableElement(element), pid: 1)
    #expect(await table.count == 1)

    // Wait briefly then expire
    try? await Task.sleep(for: .milliseconds(10))
    await table.expireStale()
    #expect(await table.count == 0)

    let resolved = await table.resolve(handleId)
    #expect(resolved == nil)
}

@Test func removeByPid() async {
    let table = HandleTable(ttl: 60)
    let element = AXUIElementCreateSystemWide()
    _ = await table.store(SendableElement(element), pid: 100)
    _ = await table.store(SendableElement(element), pid: 100)
    _ = await table.store(SendableElement(element), pid: 200)
    #expect(await table.count == 3)

    await table.removeHandles(forPid: 100)
    #expect(await table.count == 1)
}
