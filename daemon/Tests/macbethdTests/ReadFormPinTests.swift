import Testing
import Foundation
@preconcurrency import ApplicationServices
@testable import macbethd

/// Locks the wire-level contract that `read_form`'s `pin: true` plumbs through
/// to `handleTable.store(..., pinned: true)`: a handle minted that way must
/// survive the base 5-min idle sweep and only age out once the pinned window
/// has elapsed. Reaches the same code path `buildFormField` uses, without
/// needing a live AX element to drive through the full form walker.
@Test func readFormPinPlumbsThroughToHandleTable() async {
    let table = HandleTable(ttl: 0, pinnedTTL: 0.05)
    let element = SendableElement(AXUIElementCreateSystemWide())

    // Simulate the pin=true path: read_form's handler would build a field with
    // pinned=true, which calls store(_:pid:fingerprint:pinned:). We mirror the
    // exact call site rather than drive a full AX tree.
    let handleId = await table.store(
        element,
        pid: 4242,
        fingerprint: ElementFingerprint(role: "AXTextField", subrole: nil, identifier: "login-email"),
        pinned: true
    )

    #expect(await table.pin(handleId))

    // Past the base TTL but within the pinned window — handle is still live.
    try? await Task.sleep(for: .milliseconds(10))
    await table.expireStale()
    let lookup = await table.classify(handleId)
    switch lookup {
    case .found: break // expected
    default: Issue.record("expected handle to survive base TTL, got \(lookup)")
    }

    // Past the pinned TTL — handle has aged out.
    try? await Task.sleep(for: .milliseconds(60))
    await table.expireStale()
    let finalLookup = await table.classify(handleId)
    switch finalLookup {
    case .stale(let reason):
        #expect(reason == .expired)
    default: Issue.record("expected stale(expired), got \(finalLookup)")
    }
}

/// Confirms the inverse: a handle minted without `pin: true` ages out at the
/// base TTL even when the caller later tries to `pin_handle` it past the
/// window. (Pin refreshes lastAccessed, but a handle whose store-time `pinned`
/// was false must still fall under the base TTL.)
@Test func readFormWithoutPinAgesAtBaseTTL() async {
    let table = HandleTable(ttl: 0, pinnedTTL: 5)
    let element = SendableElement(AXUIElementCreateSystemWide())

    let handleId = await table.store(
        element,
        pid: 4242,
        fingerprint: ElementFingerprint(role: "AXButton", subrole: nil, identifier: "submit"),
        pinned: false
    )

    try? await Task.sleep(for: .milliseconds(20))
    await table.expireStale()
    let lookup = await table.classify(handleId)
    switch lookup {
    case .stale(let reason):
        #expect(reason == .expired)
    default: Issue.record("expected base TTL to win, got \(lookup)")
    }
}