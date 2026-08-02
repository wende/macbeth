# Element handle lifecycle

An element handle (`h_0`, `h_1`, …) is an opaque id for one accessibility element inside
one running daemon. This document is the contract: what keeps a handle valid, what
retires it, and what each failure means.

## Handles are canonical

The daemon issues **one handle per element**, not one per query. Storing an element that
already has a live handle returns that handle, so:

- repeating `query_tree` over an unchanged tree returns the ids you already hold
- handles obtained earlier keep working across unrelated queries
- `get_element`, `read_form` and `query_tree` agree on the id for the same element
- reconnecting to an already-connected app returns its existing app handle

An agent can therefore cache what it discovered, batch several actions against one tree
snapshot, and plan more than one step ahead.

**Ids are never reused.** Once a handle is retired its id stays dead; a caller holding it
gets an error rather than someone else's element.

### How identity is decided

`AXUIElement` is a CoreFoundation type whose references compare by target identity
(`CFEqual`/`CFHash`), not by pointer, so two references fetched at different times for the
same UI object are equal. `HandleTable` keys its canonical index on that
(`AX/ElementIdentity.swift`).

Two host-app behaviours bound the guarantee:

- **Apps that vend a fresh proxy per query** — Chromium/Electron web content especially,
  and some Java/Qt bridges — can return a non-equal reference for the same on-screen
  element. Deduplication then misses and a new handle is minted. That is the behaviour
  macbeth had everywhere before canonicalisation, so nothing regresses; native Cocoa apps
  get the stability, web content may not. A synthetic structural key for those apps is
  possible future work.
- **Apps that recycle views** (`NSTableView` row reuse, list virtualisation) can hand the
  same reference to a *different* element. That is the dangerous direction, so the daemon
  records each element's role, subrole and `AXIdentifier` when it issues a handle and
  re-checks them on resolve. A contradiction retires the handle (`reason: "recycled"`)
  instead of acting on the wrong control. Titles and values are deliberately not part of
  identity — a button that flips between "Play" and "Pause" is the same button. Missing
  attributes never count as a contradiction, so a busy app answering with errors cannot
  fabricate staleness.

## Invalidation boundaries

| Boundary | Error | `data.reason` |
|---|---|---|
| Unused past the idle TTL (5 min) and not pinned | `stale_handle` (-32010) | `expired` |
| App destroyed the element (re-render, view teardown) | `stale_handle` | `destroyed` |
| App reused the reference for a different element | `stale_handle` | `recycled` |
| Owning app quit, or its connection was evicted | `stale_handle` | `app_terminated` |
| A concurrent call raced a pin/unpin lookup (no liveness check) | `stale_handle` | `transient` |
| Daemon restarted, or the id was never issued | `unknown_handle` (-32011) | `never_issued` |

What stays valid: unrelated `query_tree` / `get_element` / `read_form` calls, actions on
other elements, app re-connects, and any interval shorter than the TTL. `pin_handle` (and
`Locator.scope()`, which pins automatically) exempts a handle from TTL expiry — nothing
else.

### Stale vs unknown

They differ in what recovery is possible:

- **stale** — the id was real and its element is gone. Re-resolve from the query path that
  produced it, or re-run `query_tree`. `data.reason` says which boundary was crossed.
- **unknown** — this daemon never issued the id. Retrying or re-resolving *that id* can
  never help; it means a typo, a handle invented by the caller, or one left over from a
  previous daemon process (handles do not survive a daemon restart).

Both remain JSON-RPC errors, i.e. call results — neither counts toward `ServerHealth`, so
a routine re-render can't trip an MCP host's circuit breaker.

Very old invalidation records are dropped under a bound; ids whose specific reason has
aged out report the generic `expired`. The classification degrades stale→stale, never
stale→unknown, so a real handle is never reported as one that never existed.

### Client behaviour

`ScopedLocator` re-resolves from its query path and retries once on **either** code. The
query path alone isn't always enough: app handles are daemon-local too, so a restart kills
the app handle as well, and the new daemon may already have issued that same `h_N` to a
different app — replaying the query against it would act on the wrong window. So recovery
re-acquires the app handle (`AppHandle.reconnect()`, by pid) when it must:

- on `unknown_handle`, which proves the id came from another daemon process
- on any other stale reason *only if* the replayed query is rejected for the app handle
  (`app_not_found`), because `connect_app` waits for Electron web content to build and
  must not sit on the path of an ordinary TTL re-resolve

Locators built from an `AppHandle` inherit the reconnect callback; a bare `Locator`
constructed by hand has none and surfaces `app_not_found` instead. If the app itself
relaunched, its pid changed and `reconnect()` fails — connect again by name.

The stale/unknown distinction is preserved for agents and direct RPC callers, who see
`[stale_handle]` / `[unknown_handle]` and the reason. `isRecoverableHandleError()`
(`client/src/errors.ts`) also still recognises the pre-typed-code messages, so an updated
client works against an older daemon binary.

## Acceptance criteria

Sources: issue #32. Automated coverage is in
`daemon/Tests/macbethdTests/HandleTableTests.swift` and
`client/src/__tests__/{handle-lifecycle,locator}.test.ts`; the manual checks need a real
app and Accessibility permission.

### Automated

- [x] **AC1 — Stable across repeated queries.** Storing the same element repeatedly returns
  one id, and three consecutive walks over an unchanged tree produce identical id lists.
  (`repeatedWalksOverAnUnchangedTreeReturnTheSameHandles`, `sameElementReusesItsHandle`)
- [x] **AC2 — Earlier handles survive later queries.** Every id from the first walk still
  resolves after subsequent walks. (`repeatedWalksOverAnUnchangedTreeReturnTheSameHandles`)
- [x] **AC3 — Distinct elements never collide, ids are never reused.** Different elements
  get different ids; a retired id is not handed out again.
  (`distinctElementsGetDistinctHandles`, `handleIdsAreNeverReused`)
- [x] **AC4 — Tree changes retire the right handle.** A recycled reference retires the old
  id and mints a new one; a changed title or value does not; and a read that failed to
  fetch an attribute neither retires the handle nor erases the identity already recorded.
  (`recycledReferenceRetiresTheOldHandle`, `changingTitleOrValueDoesNotRetireAHandle`,
  `missingAttributesNeverCountAsAConflict`,
  `aPartialReadDoesNotErasePreviouslyRecordedIdentity`)
- [x] **AC5 — Stale is distinguishable from unknown, with a reason.** Expired, destroyed,
  recycled and app-terminated all report `stale_handle` with their own reason; a
  never-issued id reports `unknown_handle`, and the first authoritative reason survives a
  late-landing liveness probe. (`expiredHandlesAreStaleNotUnknown`,
  `neverIssuedHandlesAreUnknown`, `terminatedAppsReportTheirOwnReason`,
  `theFirstInvalidationReasonWins`, `handle lifecycle errors` suite)
- [x] **AC6 — Pinning is the only TTL exemption.** A pinned handle survives expiry and
  keeps its id; unpinning restores normal expiry.
  (`pinnedHandlesSurviveExpiryAndKeepTheirId`)
- [x] **AC7 — Bounded memory.** Invalidation records stay under their cap, and dropped
  records degrade to `expired` rather than `unknown`. (`invalidationRecordsStayBounded`)
- [x] **AC8 — Recovery still works end to end.** A scoped locator re-resolves and retries
  once on stale *and* on unknown, re-acquires the app handle when that is what died, keeps
  `connect_app` off the ordinary TTL path, and does not retry errors re-resolving cannot
  fix. (`locator.test.ts`)
- [x] **AC9 — Boundaries are documented.** This file, plus `ElementHandle` in
  `protocol/schema.ts` and the `query_tree` MCP tool description.

### Manual (needs a real app)

Run against a native Cocoa app first — System Settings, TextEdit or Xcode.

- [ ] **AC10 — Same handles from a real app.** `query_tree` twice without touching the app;
  the two trees are identical, including every `h:` id.
- [ ] **AC11 — Cached handle stays usable.** Take a button's handle from the first tree,
  run `query_tree` twice more, then `click` that original handle. It works, with no
  re-query in between.
- [ ] **AC12 — Batching.** From one tree, `fill` a text field and `click` a button using
  handles only — no `query_tree` between the two actions.
- [ ] **AC13 — Destroyed element.** Handle a control in a sheet or dialog, close it, then
  act on the handle: `stale_handle` with reason `destroyed` (or `expired` if the app
  reuses the element lazily), never a wrong-element action.
- [ ] **AC14 — Unknown id.** `dump_attributes` with `h_99999`: `unknown_handle`.
- [ ] **AC15 — Daemon restart.** Kill `macbethd`, then act on a pre-restart handle. The
  daemon reports `unknown_handle`; a `ScopedLocator` derived from an `AppHandle` recovers
  by itself (reconnect, replay, retry) and acts on the correct app. Worth running with a
  second app connected first after the restart, so the old app-handle id is taken.
- [ ] **AC16 — Electron degradation.** Repeat AC10 on Slack or VS Code. Handles may still
  churn there — expected, documented above, and not a regression. Worth recording how much
  they churn, since that decides whether the synthetic-key follow-up is worth building.
- [ ] **AC17 — Recycled reference.** Scroll a long virtualised list (Mail message list,
  Console log) far enough to recycle rows, then act on a handle from before the scroll.
  Either it still points at the same row, or it fails with `recycled` — never a silent
  action on a different row.
