import Testing
import Foundation
@preconcurrency import ApplicationServices
@testable import macbethd

/// Locks the store-time half of `read_form`'s `pin: true` contract: a handle minted
/// with `pinned: true` survives the base 5-min idle sweep and only ages out once the
/// pinned window elapses. This drives `HandleTable` at the same call site
/// `buildFormField` uses; it does not exercise param decoding in the handler, which
/// would need a live AX element and a full form walk.
///
/// Both windows are expressed as cutoffs rather than sleeps: `ttl: 0` makes an
/// unpinned handle due on the next sweep, `pinnedTTL: 60` keeps a pinned one safe
/// from it, and the reverse table retires it. Racing a 50ms window against a
/// loaded CI runner is what made the sleeping version flaky.
@Test func pinnedAtStoreSurvivesBaseTTLThenExpires() async {
    let survives = HandleTable(ttl: 0, pinnedTTL: 60)
    let element = SendableElement(AXUIElementCreateSystemWide())

    // Simulate the pin=true path: read_form's handler would build a field with
    // pinned=true, which calls store(_:pid:fingerprint:pinned:). We mirror the
    // exact call site rather than drive a full AX tree.
    let fingerprint = ElementFingerprint(role: "AXTextField", subrole: nil, identifier: "login-email")
    let handleId = await survives.store(element, pid: 4242, fingerprint: fingerprint, pinned: true)

    // The sweep that retires an unpinned handle leaves this one alone.
    await survives.expireStale()
    let lookup = await survives.classify(handleId)
    switch lookup {
    case .found: break // expected
    default: Issue.record("expected handle to survive base TTL, got \(lookup)")
    }

    // Same store, pinned window already elapsed: the pin delays expiry, it does not
    // exempt the handle from it.
    let ages = HandleTable(ttl: 60, pinnedTTL: 0)
    let agedId = await ages.store(element, pid: 4242, fingerprint: fingerprint, pinned: true)
    await ages.expireStale()
    let finalLookup = await ages.classify(agedId)
    switch finalLookup {
    case .stale(let reason):
        #expect(reason == .expired)
    default: Issue.record("expected stale(expired), got \(finalLookup)")
    }
}

/// Confirms the inverse: `pin: false` at store time leaves the handle on the base
/// TTL, so it is swept while a pinned one (`pinnedTTL: 5`) would still be live.
/// This is the assertion that makes the `pin: true` case above mean something —
/// without it, a table that pinned everything would pass both tests.
@Test func readFormWithoutPinAgesAtBaseTTL() async {
    let table = HandleTable(ttl: 0, pinnedTTL: 5)
    let element = SendableElement(AXUIElementCreateSystemWide())

    let handleId = await table.store(
        element,
        pid: 4242,
        fingerprint: ElementFingerprint(role: "AXButton", subrole: nil, identifier: "submit"),
        pinned: false
    )

    await table.expireStale()
    let lookup = await table.classify(handleId)
    switch lookup {
    case .stale(let reason):
        #expect(reason == .expired)
    default: Issue.record("expected base TTL to win, got \(lookup)")
    }
}
