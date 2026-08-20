import Testing
import Foundation
@preconcurrency import ApplicationServices
@testable import macbethd

/// Compact rendering of a lookup outcome, so expectations read as one string compare.
private func describe(_ lookup: HandleTable.Lookup) -> String {
    switch lookup {
    case .found: "found"
    case .stale(let reason): "stale:\(reason.rawValue)"
    case .unknown: "unknown"
    }
}

private func appElement(_ pid: pid_t) -> SendableElement {
    SendableElement(AXUIElementCreateApplication(pid))
}

private func fingerprint(role: String? = nil, subrole: String? = nil, identifier: String? = nil) -> ElementFingerprint {
    ElementFingerprint(role: role, subrole: subrole, identifier: identifier)
}

// MARK: - The platform assumption everything else rests on

@Test func separatelyCreatedReferencesToTheSameElementCompareEqual() {
    // AXUIElement implements CFEqual/CFHash by target identity, not pointer identity:
    // two references obtained at different times for the same UI object are equal. Handle
    // canonicalisation is built on exactly this. If this test ever fails, every dedup
    // test below fails with it — and this is the one to read first.
    let first = AXUIElementCreateApplication(4242)
    let second = AXUIElementCreateApplication(4242)

    #expect(CFEqual(first, second))
    #expect(ElementKey(first) == ElementKey(second))
    #expect(ElementKey(first).hashValue == ElementKey(second).hashValue)
    #expect(ElementKey(first) != ElementKey(AXUIElementCreateApplication(4243)))
}

// MARK: - Canonical handles

@Test func storeAndResolve() async {
    let table = HandleTable(ttl: 60)
    let handleId = await table.store(appElement(4242), pid: 4242)
    #expect(handleId == "h_0")
    #expect(describe(await table.lookup(handleId)) == "found")
}

@Test func appScopedHandleResolutionRejectsAnotherProcess() throws {
    try ensureHandleBelongsToApp("h_0", actualPid: 4242, expectedPid: 4242)
    try ensureHandleBelongsToApp("h_0", actualPid: 4242, expectedPid: nil)

    #expect(throws: RPCError.self) {
        try ensureHandleBelongsToApp("h_0", actualPid: 4242, expectedPid: 9999)
    }
}

@Test func handleLookupPreservesOwningProcess() async {
    let table = HandleTable(ttl: 60)
    let handleId = await table.store(appElement(4242), pid: 4242)

    guard case .found(_, _, let pid) = await table.lookup(handleId) else {
        Issue.record("stored handle was not found")
        return
    }
    #expect(pid == 4242)
}

@Test func sameElementReusesItsHandle() async {
    let table = HandleTable(ttl: 60)
    let identity = fingerprint(role: "AXButton", identifier: "save")

    let first = await table.store(appElement(4242), pid: 4242, fingerprint: identity)
    let second = await table.store(appElement(4242), pid: 4242, fingerprint: identity)
    let third = await table.store(appElement(4242), pid: 4242, fingerprint: identity)

    #expect(first == second)
    #expect(second == third)
    #expect(await table.count == 1)
}

@Test func distinctElementsGetDistinctHandles() async {
    let table = HandleTable(ttl: 60)
    let first = await table.store(appElement(4242), pid: 4242)
    let second = await table.store(appElement(4243), pid: 4243)

    #expect(first != second)
    #expect(await table.count == 2)
}

/// The acceptance criterion from issue #32: repeating a tree walk over an unchanged tree
/// hands back the handles the caller already has, and the earlier handles keep working.
@Test func repeatedWalksOverAnUnchangedTreeReturnTheSameHandles() async {
    let table = HandleTable(ttl: 60)
    let tree: [(pid_t, ElementFingerprint)] = [
        (4242, fingerprint(role: "AXApplication")),
        (4243, fingerprint(role: "AXWindow", identifier: "main")),
        (4244, fingerprint(role: "AXButton", identifier: "save")),
    ]

    func walk() async -> [String] {
        var ids: [String] = []
        for (pid, identity) in tree {
            ids.append(await table.store(appElement(pid), pid: pid, fingerprint: identity))
        }
        return ids
    }

    let firstWalk = await walk()
    let secondWalk = await walk()
    let thirdWalk = await walk()

    #expect(firstWalk == secondWalk)
    #expect(secondWalk == thirdWalk)
    #expect(await table.count == tree.count)
    for id in firstWalk {
        #expect(describe(await table.lookup(id)) == "found")
    }
}

@Test func handleIdsAreNeverReused() async {
    let table = HandleTable(ttl: 60)
    let element = appElement(4242)

    let original = await table.store(element, pid: 4242, fingerprint: fingerprint(role: "AXButton"))
    await table.invalidate(original, reason: .destroyed)
    let reissued = await table.store(element, pid: 4242, fingerprint: fingerprint(role: "AXButton"))

    #expect(reissued != original)
    #expect(describe(await table.classify(original)) == "stale:destroyed")
    #expect(describe(await table.classify(reissued)) == "found")
}

// MARK: - Tree changes

@Test func recycledReferenceRetiresTheOldHandle() async {
    // Same AX reference, contradictory identity: the app reused the reference for a
    // different element (view recycling). The old handle must fail rather than silently
    // start pointing at the new element.
    let table = HandleTable(ttl: 60)
    let element = appElement(4242)

    let rowOne = await table.store(element, pid: 4242, fingerprint: fingerprint(role: "AXRow", identifier: "row-1"))
    let rowNine = await table.store(element, pid: 4242, fingerprint: fingerprint(role: "AXRow", identifier: "row-9"))

    #expect(rowNine != rowOne)
    #expect(describe(await table.classify(rowOne)) == "stale:recycled")
    #expect(describe(await table.classify(rowNine)) == "found")
    #expect(await table.count == 1)
}

@Test func changingTitleOrValueDoesNotRetireAHandle() async {
    // A button that flips between "Play" and "Pause" is the same button — only role,
    // subrole and identifier participate in identity.
    let table = HandleTable(ttl: 60)
    let element = appElement(4242)

    let first = await table.store(element, pid: 4242, fingerprint: fingerprint(role: "AXButton", identifier: "transport"))
    let second = await table.store(element, pid: 4242, fingerprint: fingerprint(role: "AXButton", identifier: "transport"))

    #expect(first == second)
    #expect(describe(await table.classify(first)) == "found")
}

@Test func missingAttributesNeverCountAsAConflict() async {
    // A busy app answers attribute reads with an error. Treating that as a new identity
    // would churn handles exactly when the app can least afford extra queries.
    let table = HandleTable(ttl: 60)
    let element = appElement(4242)

    let known = await table.store(element, pid: 4242, fingerprint: fingerprint(role: "AXButton", identifier: "save"))
    let blind = await table.store(element, pid: 4242, fingerprint: .unknown)

    #expect(blind == known)
    // The richer fingerprint is retained, so a later contradiction is still caught.
    let recycled = await table.store(element, pid: 4242, fingerprint: fingerprint(role: "AXRow"))
    #expect(recycled != known)
    #expect(describe(await table.classify(known)) == "stale:recycled")
}

@Test func aPartialReadDoesNotErasePreviouslyRecordedIdentity() async {
    // known → partial → recycled. The middle read fetched the role but lost the
    // identifier; if that erased "save", the recycled reference below (same role,
    // different identifier) would have nothing to contradict and the handle would
    // silently resolve to the wrong button.
    let table = HandleTable(ttl: 60)
    let element = appElement(4242)

    let saveButton = await table.store(
        element, pid: 4242, fingerprint: fingerprint(role: "AXButton", identifier: "save"))
    let afterPartialRead = await table.store(
        element, pid: 4242, fingerprint: fingerprint(role: "AXButton"))
    #expect(afterPartialRead == saveButton)

    let cancelButton = await table.store(
        element, pid: 4242, fingerprint: fingerprint(role: "AXButton", identifier: "cancel"))

    #expect(cancelButton != saveButton)
    #expect(describe(await table.classify(saveButton)) == "stale:recycled")
}

// MARK: - Invalidation boundaries

@Test func expiredHandlesAreStaleNotUnknown() async {
    let table = HandleTable(ttl: 0)  // 0 TTL = immediate expiration
    let handleId = await table.store(appElement(4242), pid: 4242)
    #expect(await table.count == 1)

    try? await Task.sleep(for: .milliseconds(10))
    await table.expireStale()

    #expect(await table.count == 0)
    #expect(describe(await table.classify(handleId)) == "stale:expired")
}

@Test func neverIssuedHandlesAreUnknown() async {
    let table = HandleTable(ttl: 60)
    _ = await table.store(appElement(4242), pid: 4242)

    #expect(describe(await table.classify("h_999")) == "unknown")
    #expect(describe(await table.classify("not-a-handle")) == "unknown")
    #expect(describe(await table.classify("h_")) == "unknown")
}

@Test func expiredElementsGetAFreshHandleNotTheOldOne() async {
    let table = HandleTable(ttl: 0)
    let element = appElement(4242)
    let original = await table.store(element, pid: 4242)

    try? await Task.sleep(for: .milliseconds(10))
    await table.expireStale()
    let reissued = await table.store(element, pid: 4242)

    #expect(reissued != original)
    #expect(describe(await table.classify(original)) == "stale:expired")
}

@Test func terminatedAppsReportTheirOwnReason() async {
    let table = HandleTable(ttl: 60)
    let doomed = await table.store(appElement(4242), pid: 4242)
    let survivor = await table.store(appElement(4243), pid: 4243)

    await table.removeHandles(forPid: 4242)

    #expect(describe(await table.classify(doomed)) == "stale:app_terminated")
    #expect(describe(await table.classify(survivor)) == "found")
    #expect(await table.count == 1)
}

@Test func pinnedHandlesSurviveExpiryAndKeepTheirId() async {
    // Pinned TTL is longer than base TTL but still finite: a pinned handle ages out
    // after the pinned window passes without activity. (There is no `unpin` —
    // abandoning the pin is the way to release it.)
    //
    // Both windows are driven by their cutoffs, not by sleeping: `ttl: 0` makes an
    // unpinned handle due on the very next sweep while `pinnedTTL: 60` keeps a pinned one
    // safe from it, and the reverse table retires it. Sleeping past a 50ms TTL instead
    // raced the scheduler — a loaded CI runner overshoots the window and the survival
    // assertion fails.
    let survives = HandleTable(ttl: 0, pinnedTTL: 60)
    let element = appElement(4242)
    let handleId = await survives.store(element, pid: 4242)
    #expect(await survives.pin(handleId))

    // The sweep that would retire an unpinned handle leaves this one alone, and the
    // element keeps its id — a re-store returns the same handle rather than minting one.
    await survives.expireStale()
    #expect(describe(await survives.classify(handleId)) == "found")
    #expect(await survives.store(element, pid: 4242) == handleId)

    // Same handle, pinned window already elapsed: the pin delays expiry, it does not
    // exempt the handle from it.
    let ages = HandleTable(ttl: 60, pinnedTTL: 0)
    let pinnedId = await ages.store(element, pid: 4242)
    #expect(await ages.pin(pinnedId))
    await ages.expireStale()
    #expect(describe(await ages.classify(pinnedId)) == "stale:expired")
}

@Test func pinRefreshesOnUse() async {
    // The pin window is measured from the most recent activity, not from pin-time —
    // a lookup past the pinned TTL refreshes the handle and keeps it alive.
    // The refresh is only observable across a real interval, so this one has to sleep.
    // The margin matters: the assertion is that `lookup` → `expireStale` runs inside the
    // pinned window, so that gap (two actor hops) must stay well under `pinnedTTL`. A 50ms
    // window was tight enough for a loaded CI runner to overshoot; 250ms is not.
    let table = HandleTable(ttl: 60, pinnedTTL: 0.25)
    let element = appElement(4242)
    let handleId = await table.store(element, pid: 4242)
    #expect(await table.pin(handleId))

    // Past the original pinned TTL: handle is still live because lookup refreshes
    // both lastAccessed and pinnedUntil. A sweep immediately after the refresh
    // must not retire it.
    try? await Task.sleep(for: .milliseconds(300))
    _ = await table.lookup(handleId)
    await table.expireStale()
    #expect(describe(await table.classify(handleId)) == "found")
}

@Test func storeWithPinnedTrueSetsWindow() async {
    // `ttl: 0` alone would retire the handle whether or not `pinned: true` took effect, so
    // the base TTL is long and the pinned one is zero: the handle can only be swept if the
    // store-time flag actually moved it onto the pinned window.
    let table = HandleTable(ttl: 60, pinnedTTL: 0)
    let element = appElement(4242)
    let handleId = await table.store(element, pid: 4242, pinned: true)

    await table.expireStale()
    #expect(describe(await table.classify(handleId)) == "stale:expired")
}

@Test func pinningAnUnknownHandleFails() async {
    let table = HandleTable(ttl: 60)
    #expect(await table.pin("h_999") == false)
}

@Test func theFirstInvalidationReasonWins() async {
    // Liveness probes run outside the actor, so a probe that started before the app quit
    // can report `destroyed` after eviction already recorded `app_terminated`. The
    // authoritative first reason must survive, or the caller is told to re-query an app
    // that no longer exists.
    let table = HandleTable(ttl: 60)
    let handleId = await table.store(appElement(4242), pid: 4242)

    await table.removeHandles(forPid: 4242)
    await table.invalidate(handleId, reason: .destroyed)

    #expect(describe(await table.classify(handleId)) == "stale:app_terminated")
}

@Test func invalidationRecordsStayBounded() async {
    let table = HandleTable(ttl: 60, maxInvalidationRecords: 8)
    var ids: [String] = []
    for pid in 1...40 {
        ids.append(await table.store(appElement(pid_t(pid)), pid: pid_t(pid)))
    }
    for id in ids {
        await table.invalidate(id, reason: .destroyed)
    }

    #expect(await table.invalidationRecordCount <= 8)
    #expect(await table.count == 0)
    // Recent invalidations still explain themselves precisely...
    #expect(describe(await table.classify(ids[ids.count - 1])) == "stale:destroyed")
    // ...and dropped records degrade to the generic expired classification, which is
    // still stale-class, so a caller is never told a real handle was never issued.
    #expect(describe(await table.classify(ids[0])) == "stale:expired")
}

// MARK: - handleLookupError

@Test func handleLookupErrorReportsARevivedHandleAsRecoverable() async {
    // pin_handle looks the handle up without a liveness check. If the entry comes back
    // `.found` on the follow-up classify (a concurrent call revived it between the
    // failed pin and this lookup), that is still recoverable by re-resolving — it
    // needs a typed staleHandle code, or a caller on the typed-codes path re-throws
    // instead of retrying.
    let table = HandleTable(ttl: 60)
    let handleId = await table.store(appElement(4242), pid: 4242, fingerprint: fingerprint(role: "AXButton"))
    let outcome = await table.classify(handleId)

    let error = handleLookupError(handleId, outcome)

    guard case .staleHandle(_, let erroredHandleId, let reason) = error else {
        Issue.record("expected .staleHandle, got \(error)")
        return
    }
    #expect(erroredHandleId == handleId)
    #expect(reason == "transient")
}

// MARK: - Fingerprint semantics

@Test func fingerprintConflictsOnlyOnContradiction() {
    let button = fingerprint(role: "AXButton", subrole: "AXCloseButton", identifier: "close")

    #expect(button.conflicts(with: button) == false)
    #expect(button.conflicts(with: .unknown) == false)
    #expect(ElementFingerprint.unknown.conflicts(with: button) == false)
    #expect(button.conflicts(with: fingerprint(role: "AXButton")) == false)
    #expect(button.conflicts(with: fingerprint(role: "AXRow", identifier: "close")))
    #expect(button.conflicts(with: fingerprint(role: "AXButton", subrole: "AXMinimizeButton")))
    #expect(button.conflicts(with: fingerprint(role: "AXButton", identifier: "open")))
}

@Test func unknownFingerprintIsEmpty() {
    #expect(ElementFingerprint.unknown.isEmpty)
    #expect(fingerprint(role: "AXButton").isEmpty == false)
}
