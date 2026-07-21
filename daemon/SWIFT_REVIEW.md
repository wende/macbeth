# Swift Daemon Architecture Review — macbethd

**Scope:** `daemon/` (Swift 6, macOS 14+). 3 SwiftPM targets, ~3.6k LOC, 49 tests
across 7 files (swift-testing `@Test`).
**Date:** 2026-07-17

## Applicability note

The `swift-architecture-skill` playbooks (MVVM, TCA, VIPER, Coordinator, …) target
SwiftUI/UIKit *app* presentation layers. `macbethd` is a headless JSON-RPC daemon with
no view layer, so those patterns don't map. This review instead judges it against the
architecture it actually is — a **layered actor-based service**: Transport → Dispatch →
Method handlers → AX/AppKit adapters, plus a side-car IPC (`GlowProtocol` + `macbeth-glow`).
Against that frame the design is sound and idiomatic. Findings below are ranked by impact.

## Verdict

**fit** — clean layering, correct Swift 6 concurrency discipline, good error modeling,
and pragmatic isolation of the messy AX/AppKit surface behind small helpers. The issues
are localized, not structural. Nothing here calls for a rewrite.

---

## Architecture at a glance

```
SocketServer ──> ClientConnection (line framing, write lock)
     │
     ▼
Dispatcher (actor) ──> Task.detached per request  ──> Method handler closures
     │                                                      │
 registeredMethods / connectionClosed                       ▼
                                          AppConnectionManager (actor) + HandleTable (actor)
                                                            │
                                                     AX / AppKit adapters
                                                (ElementQuery, TreeWalker, ElementGeometry,
                                                 SafeMouseClick, ElectronSupport)
                                                            │
                                          GlowIndicator (actor) ──pipe──> macbeth-glow helper
```

Boundaries are respected: `GlowProtocol` is AppKit-free and shared by both executables;
state lives in three actors (`Dispatcher`, `AppConnectionManager`, `HandleTable`, plus
`GlowIndicator`); the non-Sendable `AXUIElement` is contained by the `SendableElement`
wrapper. This is the right shape.

---

## Findings

### High

**H1 — `connections` in `AppConnectionManager` never shrink** (`AppConnection.swift:16,85`)
Connections are added on `connect` and only found again by PID, but nothing removes them
when a client disconnects or the target app quits. `HandleTable` has both TTL expiry and
`removeHandles(forPid:)`, but **`removeHandles(forPid:)` has no callers** — dead code
whose intent (evict on app termination) was never wired up. Long-lived daemons that
connect to many short-lived apps leak `Connection` structs and their app-level handles
indefinitely.
*Fix:* observe `NSWorkspace.didTerminateApplicationNotification` (or check
`NSRunningApplication(processIdentifier:)` liveness on access) and drop matching entries;
route it through the already-present `removeHandles(forPid:)`.

**H2 — Query resolution silently diverges from `query_tree`'s flattening**
(`ElementQuery.swift:242-268`)
`getVisibleChildren` and `shouldSkipQueryElement` exist to mirror `TreeWalker`'s
skip-anonymous-container logic, and the doc comment claims parity — but **they are never
called**. `findDescendants` (line 174) walks `getChildElements` (raw children) directly.
So `query_tree` flattens `AXGroup`/`AXScrollArea` wrappers while locator resolution does
not. A path that reads naturally off the printed tree can fail to resolve, or a `depth`
budget can be consumed differently than the user expects. This is a real correctness gap
plus dead code that lies about it.
*Fix:* either route `findDescendants` through `getVisibleChildren`, or delete the dead
helpers and update the comment to state that query descent sees the raw tree.

### Medium

**M1 — Unbounded per-request fan-out** (`Dispatcher.swift:66`, `SocketServer.swift:108`)
Every request spawns `Task.detached(.userInitiated)` and every line spawns a task group
child, with no concurrency cap. A client that pipelines thousands of requests can spawn
thousands of detached tasks, each potentially blocking on a 1.5s AX messaging timeout →
thread-pool starvation and memory spikes. Acceptable for a single trusted local client
(the current model), but worth a bounded queue or semaphore if that assumption ever
loosens. Document the single-client assumption at minimum.

**M2 — `HandleTable` grows to the size of the largest tree walk** (`TreeWalker.swift:36`)
`walkTree` stores a handle for **every** node visited (a 5k-node tree → 5k handles), all
with a fresh 5-minute TTL, even though callers typically use a handful. Memory scales with
the biggest `query_tree`/`read_form` rather than with handles actually retained.
*Options:* lazily mint handles only when serialized/returned, or give walk-minted handles a
shorter TTL than explicitly-requested ones.

**M3 — `press_key`/`press_keys` steal focus; `fill` doesn't** (`PressKey.swift:77,121` vs
`Fill.swift:145,256`)
`fill`'s keyboard path posts events with `postToPid:` (no focus steal, works on background
Electron). `press_key`/`press_keys` call `postKeyEvent`/`typeCharacter` with no `toPid:`,
falling back to the global HID tap and relying on `appManager.activate()` to foreground the
app first. Two different input-delivery models for the same underlying primitive is
surprising and makes `press_key` unusable without foregrounding. Consider threading
`connection.pid` through so both share the pid-targeted path.

**M4 — Test coverage is skewed to the pure/leaf modules**
49 tests, but they cluster on `GlowProtocol` (17), `GlowView` (9), `JSONRPC` (8),
`ElementGeometry` (5), `HandleTable` (5). The **query/tree-walk engine — the heart of the
daemon — has only `TreeSerializer` (4) tests**, and `ElementQuery`'s matching/descent logic
(regex, index selection, skip-flattening, the H2 bug) has none. `Dispatcher.dispatch`
error-mapping and `ClientConnection` line framing (partial reads, split UTF-8) are also
untested. The matching + framing logic is pure enough to test without a live app — that's
where the next tests should go.

### Low

**L1 — `isMinimized` uses a different bool bridge than everywhere else**
(`ElementGeometry.swift:170`) — `ref as? Bool` vs the codebase-standard
`(ref as? NSNumber)?.boolValue` (`TreeWalker.swift:97`). CFBoolean bridges to both, so it
works today, but the inconsistency is a latent trap. Pick one helper.

**L2 — `SocketServer` uses raw POSIX + `DispatchQueue.global()` for `accept`**
(`SocketServer.swift:75`) — correct and readable, but every accept hops onto a global-queue
continuation. Fine at this scale; noted only so it's a conscious choice, not an oversight.

**L3 — `dump_attributes` / `list_methods` / `pin`/`unpin` handlers inline in `main.swift`**
(`main.swift:130-168`) — most methods live in `Methods/` via `register*` functions; these
four are inlined in the top-level script. Minor consistency nit; moving them into
`Methods/` would make the registration list uniform.

**L4 — `numberValue` accessor is strict about JSON number vs string** (`JSONValue.swift:60`)
— `intValue`/`numberValue` return nil for a JSON *string* like `"5"`. Given clients send
well-typed params this is fine, but a param sent as a string (easy MCP mistake) fails with
a confusing "Missing 'x'" rather than a type error. Consider a lenient numeric coercion or
a clearer error.

---

## What's done well (keep doing)

- **Concurrency model is correct and deliberate.** `SendableElement` wrapper, `@preconcurrency
  import`, `nonisolated(unsafe)` on the write-once `verboseLogging` with a comment justifying
  it, actor isolation on all mutable state. No obvious data races.
- **Error taxonomy is excellent.** `RPCError` → `JSONRPCErrorData` with a stable code range
  (-32000..-32009), OSA-error classification (`RunAppleScript.swift:62`), and the
  machine-detectable `stale-element` marker contract (`ElementValidity.swift`) documented on
  both sides of the client boundary.
- **`GlowIndicator` is textbook best-effort side-car design** — lazy spawn, terminationHandler
  reaping, EPIPE-as-throw (SIGPIPE ignored process-wide), token-based external scopes with
  lease expiry, and a hard-kill fail-safe on connection close. Every path degrades to "log and
  continue," never blocking the RPC.
- **Connection-lifetime resource cleanup** in `SocketServer.handleClient` (the double
  `connectionClosed` call closing the begin/EOF race, `main.swift`/`SocketServer` comments) shows
  the races were actually thought through.
- **`GlowActivityTracker`** is correctly extracted as a pure, timer-free, unit-tested state
  machine — exactly the seam to pull out of AppKit.
- Bounded traversals everywhere it matters (`buildHint` maxVisit=500, `containsWebArea`
  maxDepth/maxVisit) prevent pathological trees from hanging a call.

---

## Recommended order of work

1. **H2** (query/tree parity) — correctness bug that silently breaks locators; cheap fix.
2. **H1** (connection eviction) — wire up the already-written `removeHandles(forPid:)`.
3. **M4** — add pure tests for `ElementQuery.matchesStep`/`findDescendants` and
   `ClientConnection.readLine` framing; they'd have caught H2.
4. **M3 / M2 / M1** as capacity allows.
5. Low items opportunistically.

No architectural migration is warranted — these are targeted fixes within a solid design.
