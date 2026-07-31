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

### Skills (`skills/<AppName>/`)

Each skill has a `SKILL.md` (documentation for agents) and `scripts/*.mjs` (executable automation scripts). Skills are bundled into the npm package via `prepack`. The MCP tools `list_skills` and `load_skill` make them discoverable.

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

### Error codes

RPC errors use codes -32000 to -32009. AppleScript/JXA errors are classified by OSA
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

Handles expire after 5 minutes of inactivity. Use `pin_handle` to exempt long-lived
references. `Locator.scope()` pins automatically and rediscovers on expiry. Handles
are daemon-local — if the daemon crashes, all handles are invalidated (the client
auto-reconnects and re-spawns the daemon transparently).

### Auto-reconnect

`JsonRpcClient.call()` retries once on connection errors (ECONNREFUSED, connection
closed, socket missing). The retry re-spawns the daemon via `DaemonManager.ensureRunning()`.
App handles must be re-obtained after a daemon restart since handle IDs are not stable
across daemon processes.

## Key Constraints

- **Swift 6 strict concurrency**: All daemon code must be Sendable-compliant
- **Zero external Swift dependencies**: Daemon uses only Foundation, ApplicationServices, ScreenCaptureKit, CoreGraphics, Vision
- **macOS 14+** minimum, **Node 20+**, **Swift 6.0+**
- **No mouse/CGEvent clicks**: Use AX `AXUIElementPerformAction` (press action), never `CGEvent` mouse simulation or app activation
- **Fix bugs at the source**: If the daemon/client has a bug, fix it there — don't work around it in skill scripts
