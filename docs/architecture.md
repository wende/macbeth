# Architecture

```
TypeScript Client  ←→  macbethd (Swift)  ←→  macOS Accessibility API
       ↑
  MCP Server
```

**Transport:** JSON-RPC 2.0 over a Unix domain socket (`/tmp/macbeth-<uid>.sock`), newline-delimited JSON.

**Protocol source of truth:** `protocol/schema.ts`. Swift implements the types manually.

A Swift daemon (`macbethd`) holds Accessibility and Screen Recording permissions and talks to apps via AX. The TypeScript client auto-spawns the daemon — no manual service setup.

## Layout

```
macbeth/
├── daemon/                 # Swift daemon (macbethd)
│   ├── Sources/macbethd/
│   │   ├── Transport/      # Unix socket server
│   │   ├── JSONRPC/        # Message types, dispatcher
│   │   ├── AX/             # Handles, tree walk, Electron support, safe mouse click
│   │   ├── Methods/        # One file per RPC method
│   │   └── Glow/           # Drives macbeth-glow helper
│   ├── Sources/GlowProtocol/
│   └── Sources/macbeth-glow/  # AppKit overlay renderer
├── client/                 # TypeScript client + MCP server
│   ├── src/                # client, locators, rpc, daemon, mcp
│   ├── test-electron/      # Electron e2e fixture
│   └── bin/macbeth.mjs     # npx entry
├── protocol/               # Shared JSON-RPC schema
├── skills/                 # Bundled app workflows
├── test/                   # Test harnesses and fixtures
└── scripts/                # Build, demo, CI helpers
```

## Design notes

- **Handles** — Opaque IDs (`h_0`, …) in a server-side table with a 5-minute idle TTL (60 min when pinned, refreshed on use). Canonical: the same element keeps the same ID across queries, and IDs are never reused. A retired handle reports `stale_handle` with a reason; an ID this daemon never issued reports `unknown_handle`. Locators re-resolve and retry on both (common after Electron re-renders). `pin_handle` (bulk: `handleIds[]`) and `pin: true` on the minting methods (`read_form` / `query_tree` / `get_element`) for long-lived refs; `Locator.scope()` pins automatically. Pins are finite — there is no `unpin_handle`. Contract: [handle-lifecycle.md](handle-lifecycle.md).
- **Auto-wait** — Click/fill poll until the element appears or timeout (default 30s).
- **Lazy locators** — Chains do no RPC until a terminal method.
- **Electron** — Detect stock and branded Electron bundles, enable Chromium’s AX tree with `AXManualAccessibility` only (not `AXEnhancedUserInterface`, which resizes windows), and report whether the web area exposes descendants. Prefer AX actions; synthesize keystrokes or safe mouse clicks when frameworks need real events.
- **Daemon lifecycle** — Client spawns as subprocess; shuts down on `close()`. Auto-reconnect re-spawns on connection errors; app handles must be re-obtained after a restart.
- **Zero external Swift deps** — Foundation, ApplicationServices, ScreenCaptureKit, CoreGraphics, Vision.
- **Swift 6 strict concurrency** — Sendable-compliant; `AXUIElement` wrapped as `@unchecked Sendable`.

## Adding an RPC method

1. Params/result types in `protocol/schema.ts`
2. Swift handler in `daemon/Sources/macbethd/Methods/<Method>.swift`
3. Register in `daemon/Sources/macbethd/main.swift`
4. TypeScript client method in `client/src/client.ts`
5. MCP tool in `client/src/mcp.ts` if exposing to agents

## Error codes

RPC errors use `-32000`–`-32009`. AppleScript/JXA: `-1728` → `menu_item_not_found`, `-1719` → `menu_item_disabled`, `-600`/`-609` → `app_busy`. MCP formats as `[error_kind]: message`.

## AX gaps

Some hosts (Unity, certain Electron IDEs) expose only window + menu bar. Prefer native AX menus (`select_menu_item`), OCR (`extract_text`), and screenshots for those apps. `query_tree` already contains the menu hierarchy; `list_menu_bar` is the compact menu-only view. `read_form` works best on native apps with proper AX (`AXValue`, `AXTitleUIElement`, settable attributes).
