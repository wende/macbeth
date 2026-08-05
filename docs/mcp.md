# MCP server

macbeth ships an MCP server so LLM agents can automate macOS apps through tool calls.

The published npm package ships a **prebuilt, notarized universal daemon** — there is no build step, and no Swift toolchain is required. `npx macbeth` downloads the package and starts the MCP server over stdio, so the same command works as a universal MCP entry point for any agent that speaks the [Model Context Protocol](https://modelcontextprotocol.io).

## Install

**Claude Code** — register the server from your terminal:

```bash
claude mcp add macbeth -- npx -y macbeth
```

That's the whole install. `npx -y` fetches `macbeth` on first launch (and caches it), the daemon binary is bundled, and macOS prompts for Accessibility the first time a tool runs.

Any MCP client that launches a stdio server takes the same command (`npx -y macbeth`, no args). The universal config block is:

```json
{
  "mcpServers": {
    "macbeth": {
      "command": "npx",
      "args": ["-y", "macbeth"]
    }
  }
}
```

- **Claude Desktop** → `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Claude Code (project)** → `.mcp.json` in the repo root
- **Cursor** → `~/.cursor/mcp.json`
- **Other clients** → drop the `macbeth` entry into that client's `mcpServers` map.

To pin a version instead of always taking the latest, use `npx -y macbeth@0.2.4` (or install globally with `npm i -g macbeth` and use `"command": "macbeth"`).

Grant **Accessibility** (and **Screen Recording** for screenshots/OCR). The client auto-spawns `macbethd`; no background service to install.

## Verify it works

After registering, confirm the two macOS permissions and daemon are healthy:

```bash
npx macbeth doctor   # prints Accessibility + Screen Recording status, exits non-zero if AX is denied
```

When something is wrong, `doctor` doesn't just print an error — it emits a
**"paste this to your agent to fix it"** block: a self-contained prompt with the
exact error, your environment (macbeth/macOS/Node versions), and a link to the
troubleshooting guide. Copy it straight into Claude Code, Cursor, or any agent
and let it walk you through the fix. The same block is printed for any
unexpected CLI failure.

Then ask your agent to run this **smoke-test prompt**:

> Using the macbeth MCP tools, call `list_apps` and tell me which apps are connectable through Accessibility. Then `query_tree` Finder's front window and report the first few elements you see.

A healthy install lists running apps under a **Connectable through Accessibility** heading and returns a small accessibility tree for Finder. If every app lands under the not-connectable heading with AX `-25211 api_disabled`, Accessibility permission is missing. If any step fails — the tools don't appear, `list_apps` errors, or the tree comes back empty — run `npx macbeth doctor` and paste its fix block to your agent, or see **[TROUBLESHOOTING.md](../TROUBLESHOOTING.md)**.

### Do I need `connect_app`?

No. Every app-taking tool (`query_tree`, `click`, `fill`, `screenshot`, …) connects on its own — pass an app name or PID and it resolves. `connect_app` is a preflight you call deliberately: to confirm an app is reachable through Accessibility before driving it, to see exactly how a fuzzy name resolved, or to give an Electron app a longer `readyTimeoutMs`. It returns an app handle (`h_3`) that any other tool accepts in its `app` argument, which pins the target to that exact process instead of re-running fuzzy name matching.

## Updating

```bash
npx macbeth update          # install the latest signed GitHub release
npx macbeth update --check  # report only
```

`update` checks [`wende/macbeth`](https://github.com/wende/macbeth/releases), compares versions, and installs the notarized package via `npm install -g` (falls back to the npm registry if the release has no tarball). Override the repo with `MACBETH_UPDATE_REPO`.

## Tools

| Tool | Description |
|---|---|
| `list_daemon_methods` | List registered daemon RPCs for MCP parity checks |
| `begin_activity` / `end_activity` | Bracket external computer-control work with the interaction glow |
| `list_apps` | List running macOS apps, split into Accessibility-connectable and running-but-not-connectable (with the AX code and what to do instead) |
| `connect_app` | Optional preflight — verify Accessibility reachability, see how a fuzzy name resolved, or warm an Electron tree. Returns an app handle you can pass as `app` to any other tool |
| `list_windows` | List open windows across macOS Spaces without activating them; `app` is optional, so one call answers "is app X open?" |
| `query_tree` | Accessibility tree as text or JSON, including menus and web-content readiness diagnostics |
| `get_element` | Find an element by query or handle |
| `dump_attributes` | Dump all AX attributes for a handle |
| `read_form` | Read form-like controls from an app or subtree |
| `click` | Click a UI element (auto-waits) |
| `fill` | Set a text field value (auto-waits) |
| `wait_for` | Wait for existence, value, change, or enabled state |
| `press_key` | Activate target app, send keyboard input, report the dispatch outcome |
| `press_keys` | Activate target app, send a key sequence, report the dispatch outcome |
| `screenshot` | Capture the default visible window or a window selected by `list_windows` ID |
| `extract_text` | OCR the default visible window, a selected window ID, or a supplied PNG |
| `pin_handle` / `unpin_handle` | Control element-handle expiry |
| `list_menu_bar` / `select_menu_item` | Compactly inspect and select native menu items through AX; `query_tree` usually makes the list call unnecessary |
| `run_applescript` | AppleScript or JXA (interactive or read-only), with a per-call `timeout` in seconds (default 30, max 300) |
| `list_shortcuts` / `run_shortcut` | Inspect and run Apple Shortcuts |
| `list_skills` / `load_skill` / `run_skill_script` | Discover and run bundled skills. `load_skill` with no arguments loads the core macbeth usage guide |

## Listing windows

`list_windows` reads the WindowServer catalog, so it answers "is app X open, and
what is it showing?" without connecting to an app or walking an accessibility
tree:

```jsonc
// every app that owns a window
{ "name": "list_windows", "arguments": {} }
// one app and its helper processes
{ "name": "list_windows", "arguments": { "app": "Unity" } }
```

Each entry carries `windowId`, `title`, `ownerName` / `ownerPid` / `bundleId`,
`frame`, `layer`, `onScreen`, `active`, `minimized`, AX `role` / `subrole`,
`kind`, `capturable`, and `default` (the window `screenshot` and `extract_text`
capture for that owner when no `windowId` is given). `role`, `subrole`, and
`minimized` are `null` when the app exposes no AX window for the surface — for
example when Accessibility permission has not been granted.

By default only real windows are returned. Pass `includeAllSurfaces: true` to
also see menu-bar strips, overlays, and the tiny bookkeeping surfaces some apps
register (`kind` explains which is which — useful when a window you expected to
capture is missing).

**`windowId` is not an element handle.** It is a WindowServer ID issued by
macOS: it has no 5-minute TTL, is unaffected by `pin_handle` / `unpin_handle`,
and survives daemon restarts. It stays valid until the window closes; a reopened
window gets a new ID. Element handles from `query_tree` / `get_element` (`h_0`,
`h_1`, …) are the ones that expire.

## Running scripts

`run_applescript` takes the script in **`source`** (not `script` or `code`), and
`language` is exactly `"AppleScript"` or `"JavaScript"` — JXA is `"JavaScript"`:

```jsonc
{ "source": "tell application \"Finder\" to get name of every window" }
{ "source": "Application('Finder').windows().map(w => w.name()).join(', ')",
  "language": "JavaScript" }
```

`interaction` is `"interactive"` (default — the script may control apps and
input) or `"read_only"`, and `timeout` is in seconds.

## Timeouts and server health

Timeouts are per operation. `run_applescript` takes a `timeout` in seconds (default 30,
max 300); `click`, `fill` and `wait_for` take their own `timeout`. The daemon enforces the
script deadline in a separate `osascript` process and clamps the request to 0.1–300s, so a
hand-written RPC call cannot ask for an unbounded run.

Exceeding a deadline stops that operation and returns a typed `[timeout]` tool error for
that call. It is deliberately not a transport failure:

- the daemon connection stays open and every other tool keeps working, so repeated script
  timeouts never make `connect_app` (or anything else) unreachable;
- the client's health tracking counts only transport failures — a broken socket, a daemon
  that won't start — so operation timeouts cannot accumulate into an unhealthy server or
  trip a host's circuit breaker;
- the fix for a script that genuinely needs longer is a larger `timeout`, not a retry.

`MacbethClient.health` exposes the same accounting to library users
(`healthy`, `consecutiveTransportFailures`, `operationTimeouts`).

## Skills

Call `load_skill` with **no arguments** to load the [core macbeth skill](../skills/macbeth/SKILL.md) — how agents should use the MCP tools (discovery, locators, actions, handles, fallbacks). Pass `name` for an app-specific skill.

```jsonc
{ "name": "load_skill" }                          // core usage guide
{ "name": "load_skill", "arguments": { "name": "Safari" } }
```

Drop a `SKILL.md` into `skills/<name>/` to teach agents app-specific workflows. Load via `list_skills` / `load_skill`.

Bundled: [macbeth](../skills/macbeth/SKILL.md) (core), Calendar, Contacts, Mail, Maps, Messages, Music, Notes, Reminders, Safari, System Settings, Logic Pro, and [Electron](../skills/electron/SKILL.md) (web-area trees, fill/click strategies, gotchas).

Client API for scripts and tests: [skills/DEVELOPING_MACBETH.md](../skills/DEVELOPING_MACBETH.md). Interaction chrome: [interaction-glow.md](interaction-glow.md).
