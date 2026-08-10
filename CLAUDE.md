# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Macbeth

Playwright-style automation framework for native macOS apps via the Accessibility API. A Swift daemon (`macbethd`) talks to apps through AX APIs, a TypeScript client communicates with it over JSON-RPC 2.0 on a Unix socket, and an MCP server exposes tools for LLM agents.

## Build & Test Commands

```bash
# Swift daemon (universal binary → client/bin/macbethd)
./scripts/build-daemon.sh

# TypeScript client
cd client && npm run build        # compile once
cd client && npm run dev          # watch mode

# Tests
cd client && npm test             # vitest (single run)
cd client && npx vitest run src/__tests__/locator.test.ts  # single test file
cd daemon && swift test           # Swift tests
```

## Architecture

```
TypeScript Client ←→ macbethd (Swift) ←→ macOS Accessibility API
       ↑
  MCP Server (for LLM agents)
```

**Communication**: JSON-RPC 2.0 over Unix domain socket (`/tmp/macbeth-<uid>.sock`), newline-delimited JSON framing.

**Protocol schema**: `protocol/schema.ts` is the canonical source of truth for all RPC types. Swift implements these manually.

### Client (`client/src/`)

- `client.ts` — `MacbethClient` (daemon lifecycle, RPC) and `AppHandle` (per-app API surface)
- `elements.ts` — `Locator` class: chainable, immutable, lazy (no RPC until a terminal method like `.click()` or `.fill()`)
- `rpc.ts` — JSON-RPC client over Unix socket
- `daemon.ts` — Auto-spawns and manages the daemon subprocess
- `mcp.ts` — MCP server tool registration and handlers
- `applescript.ts`, `native-bridge.ts`, `shell.ts`, `shortcuts.ts` — Utilities used by skills

### Daemon (`daemon/Sources/macbethd/`)

- `AX/HandleTable.swift` — Opaque element handles (`h_0`, `h_1`, ...) with 5-min TTL
- `AX/AppConnection.swift` — App connection with fuzzy name matching
- `AX/TreeWalker.swift` + `TreeSerializer.swift` — Recursive AX tree traversal and output
- `AX/ElementQuery.swift` — Resolves locator query paths to AX elements
- `Methods/` — One file per RPC method (Click, Fill, WaitFor, Screenshot, etc.)
- `JSONRPC/Dispatcher.swift` — Routes incoming calls to method handlers
- `Transport/SocketServer.swift` — Unix socket server
- `Logging/RequestLogger.swift` — Per-RPC audit log (NDJSON, rotated) written to `~/Library/Caches/macbeth/logs/`

### Request logging

Every RPC call is recorded as one NDJSON line. The daemon writes the log
(`Logging/RequestLogger.swift`); the client never touches the file. This is the
persistent companion to the live `--verbose` stderr trace, which still only flows
to whoever owns the daemon's terminal.

- **Location** — `~/Library/Caches/macbeth/logs/requests.log`, rotated to
  `requests-<ISO8601UTC>.log` siblings. Resolved via
  `FileManager.default.urls(for: .cachesDirectory)`, so sandboxed and `$HOME`-overridden
  test runs land where they should. Daemon has no bundle ID, so the literal
  `macbeth/` subdir is hardcoded.
- **Format** — one JSON object per line: `ts`, `connectionID`, `requestID`,
  `method`, `paramsBytes`, `resultBytes`, `durationMs`, `ok`, `errorCode`,
  `paramsPreview`, `resultPreview`. Previews are capped at ~1 KB on a UTF-8
  boundary; base64 payloads (screenshot `data` field) become `{"bytes": N}` so a
  busy traffic minute doesn't turn into megabytes. Parse failures get
  `method: null`, `ok: false`, `errorCode: -32700`.
- **Defaults** — on. Defaults: 5 MB per file, 10 rotated siblings (~55 MB total
  ceiling), 1024-byte body preview budget.
- **CLI flags** — `--no-log`, `--log-dir <path>`, `--log-max-file-mb <int>`,
  `--log-max-files <int>`. Flags win over env vars.
- **Env vars** — `MACBETH_NO_LOG=1`, `MACBETH_LOG_DIR=<path>`,
  `MACBETH_LOG_MAX_FILE_MB=<int>`, `MACBETH_LOG_MAX_FILES=<int>`. Already empty
  in the inherited env, so they round-trip cleanly through `client/src/daemon.ts`.
- **Failure surface** — none. Init failure prints one stderr line and runs
  without the log; append failure rate-limits one `vlog` line per minute. RPC
  callers are never affected.

Inspect fast:

```bash
jq -r '[.ts, .method, .ok, .durationMs] | @tsv' \
  ~/Library/Caches/macbeth/logs/requests.log | tail -50
```

### Skills (`skills/<AppName>/`)

Each skill has a `SKILL.md` (documentation for agents) and optional `scripts/*.mjs`. Skills are bundled into the npm package via `prepack`. The MCP tools `list_skills` and `load_skill` make them discoverable — `load_skill` with no arguments loads the core `skills/macbeth/` usage guide.

### Native bridge (`client/native/apple_data.swift`)

Swift script executed directly for EventKit access (Calendar, Reminders, Contacts). Returns JSON. Used by skills that need data access beyond what AX provides.

## Adding a New RPC Method

1. Define params/result types in `protocol/schema.ts`
2. Create Swift handler in `daemon/Sources/macbethd/Methods/<Method>.swift`
3. Register the handler in `daemon/Sources/macbethd/main.swift`
4. Add TypeScript client method in `client/src/client.ts`
5. If exposing via MCP, add tool in `client/src/mcp.ts`

## Dev Notes

### Electron / Chromium apps

Electron apps (Slack, VS Code, Discord) keep their accessibility tree disabled until an
assistive-technology client is detected. On connect, the daemon sets the
`AXManualAccessibility` attribute (`AppConnection.connect` → `ElectronSupport.swift`) on the
app's AXUIElement to switch the web-content tree on, then polls for an `AXWebArea` to appear
(default 3s, tunable via `connect_app`'s `readyTimeoutMs`) before returning. We deliberately
do NOT set `AXEnhancedUserInterface` — it causes window resize/reposition bugs in Electron.

`Connection.runtime` (native/electron/unknown) is computed once at connect and read by the
action methods.

Runtime detection recognises both stock Electron bundles and branded distributions that
rename `Electron Framework.framework` but retain `ElectronAsarIntegrity` metadata,
`ChromiumBaseVersion`, or a Chromium `Helper (Renderer)` + `*Framework.framework` layout.
App resolution also reads `CFBundleAlternateNames`, so a declared product alias is reported
explicitly rather than looking like an unexplained fuzzy bundle-id match.

**Action strategies** (both default to `"auto"`, plumbed through `protocol/schema.ts`, the TS
`Locator`, and the MCP tools):

- `fill` — `"auto" | "ax" | "keyboard"`. Auto writes `kAXValueAttribute`, verifies by reading
  back, and falls back to keyboard synthesis; on Electron it always synthesizes keystrokes
  (posted via `CGEvent.postToPid`) because a "successful" AX write can leave React-style state
  stale (the framework never sees an input event). See `Fill.swift`.
- `click` — `"auto" | "ax" | "mouse"`. Auto tries `AXPress` on the element, then its parent and
  first child (Chromium often puts the action on an adjacent node), then a synthetic mouse click
  at the element center. The mouse path raises only the owning window, restores the previous
  app/window and cursor, and accepts `waitForIdleMs` to avoid a mid-keystroke focus steal. See
  `Click.swift` and `SafeMouseClick.swift`.

**Stale handles** — Electron re-renders can invalidate an `AXUIElement` sooner than the handle
TTL. `ensureElementValid` (`ElementValidity.swift`) detects `kAXErrorInvalidUIElement` and throws
an error containing `stale-element`; the TS `ScopedLocator` keys off that marker to re-resolve
from the original query path and retry once. Raw `h_N` handles from `query_tree` carry no path,
so the error tells the caller to re-run `query_tree`.

### Discovery and connection contract

`connect_app` is optional: every app-taking tool resolves its `app` argument through
`MacbethClient.connect` first. What it adds is a deliberate preflight — a reachability
check, the resolved match kind, and a tunable Electron `readyTimeoutMs`. Its `appHandle`
is not decorative: `app` accepts `h_<n>` (see `client/src/app-target.ts`), and the daemon
resolves it straight out of `AppConnectionManager.connections`, skipping fuzzy matching.
Unknown or dead handles fail with an `app_not_found` that says to reconnect by name/PID.

`list_apps` probes each running app with the same AX role read that `connect` performs
(`probeAccessibility`, 0.25s messaging timeout) and reports `connectable` /
`permission_required` / `not_connectable`. "Running" and "automatable" are different
things — listing a launcher like Unity Hub as if it were drivable is what makes discovery
untrustworthy.

Raw `AXError` codes never reach a caller uninterpreted. `axErrorInfo`
(`AX/AXErrorInfo.swift`) is the single mapping from code → name, plain-language
explanation, and likely next action; it feeds both `list_apps` entries and the
`app_not_found` message and `data` payload thrown by a failed connect.

### AX limitations in complex apps (Unity, Electron IDEs)

Apps like Unity expose only window + menu bar through the Accessibility API. Panel
internals (Inspector, Hierarchy, Scene) are invisible to AX queries — `query_tree`
returns a flat structure with 3-5 nodes, and `read_form` finds zero controls. This
is a host app limitation, not a macbeth bug.

For these apps, the primary interaction model is:
- **Menus**: `select_menu_item` uses AX directly (deterministic, bounded, no System
  Events). `query_tree` already includes menus; use `list_menu_bar` only for a compact
  menu-only view.
- **OCR**: `extract_text` via Vision framework bridges the AX gap — extracts on-screen
  labels, values, and field names from screenshots
- **Screenshots**: `screenshot` with optional `region` crop for visual confirmation

`read_form` works well on native macOS apps with proper AX support (System Settings,
Xcode, TextEdit, etc.) where controls expose `AXValue`, `AXTitleUIElement`, and
`AXSettable` attributes.

### Keyboard dispatch reporting

`press_key` / `press_keys` return a three-tier `outcome` (`attempted`,
`dispatched`, `verified`) plus the addressed target, evidence, and warning codes.
The classification is a pure function — `diagnoseKeyDispatch` in
`AX/KeyDispatch.swift` — so it is unit tested without a window server. Evidence
is the session key-down counter delta (confirmation only; a human at the keyboard
also advances it) and per-event `CGEvent` creation results. `dispatched` requires
the counter to account for every posted event; partial confirmation stays
`attempted`. `verified` is reserved for effect verification and is not yet
produced. Checks are observational — they annotate the result rather than
blocking a keystroke — with one exception: an app handle that no longer resolves
is an `appNotFound` error, because without a connection the events would land in
whatever app happens to be frontmost. See
`docs/keyboard-input-and-foregrounding.md`.

### Error codes

RPC errors use codes -32000 to -32011 (-32010 `stale_handle` and -32011 `unknown_handle`
carry a `data.reason`; see `docs/handle-lifecycle.md`). AppleScript/JXA errors are classified by OSA
error number: -1728 → `menuItemNotFound`, -1719 → `menuItemDisabled`, -600/-609 →
`appBusy`. The MCP layer formats these as `[error_kind]: message` for agent readability.
Scripts run in an isolated `osascript` process with a daemon-enforced deadline, so a
blocked Apple Event is terminated instead of occupying the daemon until the generic RPC
timeout. OSA -1743/-10004 maps to `permissionDenied`; -1712 maps to `timeout`.

### Operation timeouts vs server health

Timeouts are scoped to one operation and never mean the server is unhealthy — an MCP
host that counted them as transport failures would open its circuit breaker and take
unrelated tools down with them.

- `run_applescript` accepts a caller-set deadline (`timeoutMs`, MCP `timeout` in
  seconds). Bounds live in `ScriptTimeout` (`Methods/ScriptExecution.swift`) and
  `SCRIPT_TIMEOUT` (`client/src/timeouts.ts`) — 100ms–300s, default 30s — and both sides
  clamp independently. The client waits `timeoutMs + 2s` so the daemon's own typed
  timeout wins the race.
- The daemon races the child process against the deadline (`waitForScriptProcess`).
  `ScriptExitSignal.wait()` must stay cancellable: a task group only returns once every
  child finishes, so an uncancellable exit waiter would park the whole call until the
  script exited on its own and the deadline would never take effect.
- Client-side deadlines reject with a typed `JsonRpcError` (-32001,
  `data.phase === "client_wait"`), not a generic `Error`, and drop only that request —
  the socket stays open.
- `client/src/errors.ts` draws the line: a `JsonRpcError` is a result, never a transport
  failure. `ServerHealth` (`client/src/health.ts`, exposed as `MacbethClient.health`)
  counts only transport failures toward health.

### Handle lifecycle

Handles are canonical: `HandleTable` keys a per-element index on AX reference identity
(`CFEqual`/`CFHash`, see `AX/ElementIdentity.swift`), so the same element gets the same
`h_N` every time — repeated `query_tree` calls return the ids the caller already holds.
Ids are never reused. Callers pass an `ElementFingerprint` (role, subrole, `AXIdentifier`)
when storing; a contradiction on resolve means the app recycled the reference for a
different element, and the handle is retired instead of resolving to the wrong control.
Title and value are excluded from identity on purpose.

Handles expire after 5 minutes of inactivity. Use `pin_handle` to exempt long-lived
references. `Locator.scope()` pins automatically and rediscovers on expiry. Handles
are daemon-local — if the daemon crashes, all handles are invalidated (the client
auto-reconnects and re-spawns the daemon transparently).

Resolution goes through `resolveLiveHandle` (`AX/HandleResolution.swift`), which returns
three outcomes rather than one nil: live, `stale_handle` (-32010, with `data.reason` =
`expired` / `destroyed` / `recycled` / `app_terminated`), or `unknown_handle` (-32011) for
an id this daemon never issued. Liveness checks run outside the actor so a slow app can't
stall unrelated handle operations. Full contract in `docs/handle-lifecycle.md`.

`windowId` from `list_windows` is *not* one of these handles: it is a WindowServer ID
issued by macOS, so it has no TTL, ignores `pin_handle`, survives daemon restarts, and
stays valid until the window closes. Say so wherever the two appear together — agents
otherwise assume every opaque ID macbeth returns expires after five minutes.

### Window listing

`list_windows` takes an optional `appHandle`. Without one it enumerates every app that
owns a window, which is how an agent answers "is app X open?" in a single call instead of
connecting and walking a tree. Filtering, defaults, and serialisation live on
`WindowDescriptor` (`WindowDiscovery.swift`) rather than `SCWindow` so they stay testable
— ScreenCaptureKit types cannot be constructed in tests. Real windows only by default;
`includeAllSurfaces` adds menu-bar strips, overlays, and bookkeeping sentinels. AX
role/subrole/minimized are joined in per window via `AXWindowNumber` (the same ID
ScreenCaptureKit reports), under a short per-app AX messaging timeout so one hung app
cannot stall the listing.

### Auto-reconnect

`JsonRpcClient.call()` retries once on connection errors (ECONNREFUSED, connection
closed, socket missing). The retry re-spawns the daemon via `DaemonManager.ensureRunning()`.
App handles must be re-obtained after a daemon restart since handle IDs are not stable
across daemon processes — `AppHandle.reconnect()` does that by pid, and locators derived
from an `AppHandle` call it automatically when a recovery needs it (`unknown_handle`, or a
re-resolve rejected with `app_not_found`). A restarted daemon can reissue the old app
handle's id to a different app, so replaying a query without reconnecting can hit the
wrong app.

## Key Constraints

- **Swift 6 strict concurrency**: All daemon code must be Sendable-compliant
- **Zero external Swift dependencies**: Daemon uses only Foundation, ApplicationServices, ScreenCaptureKit, CoreGraphics, Vision
- **macOS 14+** minimum, **Node 20+**, **Swift 6.0+**
- **No mouse/CGEvent clicks**: Use AX `AXUIElementPerformAction` (press action), never `CGEvent` mouse simulation or app activation
- **Fix bugs at the source**: If the daemon/client has a bug, fix it there — don't work around it in skill scripts
