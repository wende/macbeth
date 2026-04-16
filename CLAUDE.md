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

### AX limitations in complex apps (Unity, Electron IDEs)

Apps like Unity expose only window + menu bar through the Accessibility API. Panel
internals (Inspector, Hierarchy, Scene) are invisible to AX queries — `query_tree`
returns a flat structure with 3-5 nodes, and `read_form` finds zero controls. This
is a host app limitation, not a macbeth bug.

For these apps, the primary interaction model is:
- **Menus**: `select_menu_item` / `list_menu_bar` (deterministic, fast)
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
