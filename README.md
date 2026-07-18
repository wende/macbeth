<p align="center">
  <img src="assets/macbeth-logo.svg" alt="Macbeth" width="300" />
</p>

<h1 align="center">Playwright for macOS apps</h1>

<p align="center">
  <a href="https://www.npmjs.com/package/macbeth"><img src="https://img.shields.io/npm/v/macbeth?style=for-the-badge&color=61202F&labelColor=1a1520" alt="npm" /></a>
  <img src="https://img.shields.io/badge/license-MIT-8B3342?style=for-the-badge&labelColor=1a1520" alt="MIT" />
  <img src="https://img.shields.io/badge/macOS-14%2B-32111A?style=for-the-badge&logo=apple&logoColor=white&labelColor=1a1520" alt="macOS" />
  <img src="https://img.shields.io/badge/MCP-ready-8B5CF6?style=for-the-badge&labelColor=1a1520" alt="MCP" />
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=for-the-badge&logo=swift&logoColor=white&labelColor=1a1520" alt="Swift" />
  <img src="https://img.shields.io/badge/TypeScript-5-3178C6?style=for-the-badge&logo=typescript&logoColor=white&labelColor=1a1520" alt="TypeScript" />
</p>

**Native AppKit · Electron/Chromium · MCP for agents** — same locator API, [Accessibility](https://developer.apple.com/documentation/accessibility) under the hood.

```bash
npm install macbeth
```

<p align="center">
  <a href="#quick-start">Docs</a> ·
  <a href="#features">Features</a> ·
  <a href="#mcp-server">MCP server</a> ·
  <a href="https://github.com/wende/macbeth/issues">Issues</a>
</p>

## Demo

> **Video demo coming soon.** Until then, run the on-screen presentation yourself:
>
> ```bash
> npm run demo:mcp
> ```
>
> That launches native + Electron fixtures through the public MCP server and walks through fills, clicks, keyboard input, screenshots, and OCR with the interaction overlays visible. Use `--fast` for a quicker paced run or `--delay-ms 1200` for a slower recording.
>
> <!-- Replace this block with an embedded demo once the video is ready:
> [![Macbeth demo](assets/demo-thumbnail.png)](https://…your-video-url…)
> -->

## Features

- **Native + Electron** — AppKit apps and Chromium-based apps share the same locator API. On connect, Electron trees are switched on via `AXManualAccessibility` and waited on until web content is ready.
- **Playwright-style locators** — chainable, immutable, lazy; no RPC until `.click()`, `.fill()`, or another terminal method.
- **Smart action strategies** — `click` (`auto` / `ax` / `mouse`) and `fill` (`auto` / `ax` / `keyboard`) with Electron-aware fallbacks (keystroke synthesis for React-style inputs; AXPress + safe mouse click for stubborn controls).
- **MCP server** — tool surface for Claude and other agents, plus bundled app skills (Calendar, Mail, Safari, System Settings, Electron, …).
- **Screenshots & OCR** — ScreenCaptureKit capture and Vision-based `extract_text` for apps with thin AX trees.
- **Interaction glow** — violet window outline, synthetic pointer on click/fill, and scan/snap on screenshots so recorded demos stay readable.
- **Menus, AppleScript, Shortcuts** — menu-bar automation, `run_applescript`, and Shortcuts integration alongside AX queries.

## How it works

```
┌──────────────┐     JSON-RPC      ┌──────────────┐     AX API    ┌─────────────┐
│  TypeScript  │◄──── over ───────►│    macbethd  │◄─────────────►│  macOS App  │
│   Client     │   Unix socket     │(Swift daemon)│               │  (any app)  │
└──────────────┘                   └──────────────┘               └─────────────┘
       ▲
       │
┌──────────────┐
│  MCP Server  │  ← Claude, or any MCP-compatible agent
└──────────────┘
```

A Swift daemon (`macbethd`) holds the Accessibility and Screen Recording permissions and communicates with apps via the macOS AX API. A TypeScript client talks to the daemon over a Unix domain socket using JSON-RPC 2.0. The client auto-spawns the daemon — no manual setup needed.

## Quick start

```ts
// script.mjs
import { connect } from "macbeth";

const app = await connect("TextEdit");
await app.window("Untitled").textField().fill("Hello from macbeth");
await app.pressKey("s", ["cmd"]);
await app.pressKeys([{ key: "return" }, { key: "tab", delayMs: 100 }]);
// process exits cleanly — no cleanup needed
```

```bash
node script.mjs
```

Scripts exit automatically when the work is done. The daemon stays warm in the background for fast subsequent runs.

### Install

```bash
npm install macbeth
```

> macOS 14 (Sonoma) or later required. On first run, macOS will prompt for Accessibility permissions.

### Build from source

```bash
# Build the Swift daemon (universal binary: arm64 + x86_64)
./scripts/build-daemon.sh

# Build the TypeScript client
cd client && npm run build
```

Maintainers: see [docs/releasing.md](docs/releasing.md) for signed and notarized
GitHub/npm releases.

### Packaged GUI test harness

The legacy unbundled Swift test package has been replaced by a regular AppKit
application bundle. Building or launching the harness registers it with macOS,
so it is visible in the Dock, Window menu, `NSWorkspace`, and `list_apps`.

```bash
npm run build:test-harness
npm run launch:test-harness
```

The launcher opens the harness in the background so it does not steal focus.
Macbeth intentionally brings it forward only for keyboard-driven actions or
coordinate-click fallbacks.

The default GUI suite avoids live keyboard input for the same reason; the
keyboard API remains unit-tested. To exercise real keyboard delivery, opt in
explicitly with `MACBETH_GUI_KEYBOARD_TESTS=1` alongside `MACBETH_GUI_TESTS=1`.

The end-to-end UI suite is intentionally local and opt-in because it requires
macOS Accessibility permission. Build the daemon and client first, then run:

```bash
./scripts/build-daemon.sh
cd client && npm run build && cd ..
MACBETH_GUI_TESTS=1 npm run test:gui
```

To audit whether demo MCP actions leave a fixture frontmost, run the opt-in
foregrounding suite (mirrors every step in `demo:mcp`; keyboard paths are
expected to fail today):

```bash
MACBETH_GUI_FOREGROUND_TESTS=1 npm run test:gui:foreground
```

### MCP-only feature demo

Run the full native + Electron presentation through the public MCP server:

```bash
npm run demo:mcp
```

The command builds the daemon, client, and fixtures, launches both apps through
the `run_applescript` MCP tool, and presents only capabilities with an observable
on-screen effect. Daemon/MCP parity and read-only introspection belong in
automated integration checks rather than creating dead time in the recording.
It arranges both fixture windows before connecting so target outlines begin on
real, final window frames, then presents native fills, clicks, and keyboard input
as the first feature section. It pauses between operations for recording,
continues through independent failures, prints screenshot paths and a final
summary, and exits nonzero when a feature fails. Use `--fast` for an
integration-test-paced run or `--delay-ms 1200` for a slower recording. The
runner always closes every fixture instance it launched, restores the app that
was foreground before the demo, and closes its MCP transport so presentation
overlays cannot outlive the run.

Accessibility and Screen Recording permissions must already be granted.
Screenshot and OCR are exercised as required checks and make the demo fail if
either capability regresses.

## API

### Connecting

```ts
import { connect, MacbethClient } from "macbeth";

// Quick — one app, manages daemon lifecycle automatically
const app = await connect("Finder");

// Full control — reuse client across multiple apps
const client = new MacbethClient({ verbose: true });
const finder = await client.connect("Finder");
const music = await client.connect("Music");
await client.close(); // shuts down daemon
```

`connect()` accepts an app name (fuzzy matched) or a PID.

### Locators

Locators are immutable and lazy. No RPC call is made until you call a terminal method like `.click()` or `.fill()`.

```ts
// Chain to narrow down the element
const submitBtn = app.window("Settings").group("Form").button("Submit");

// Reuse — locators are immutable
await submitBtn.click();
await submitBtn.waitFor();
```

Built-in locator methods for common roles:

| Method | AX Role |
|---|---|
| `.window(title)` | Window |
| `.button(title)` | Button |
| `.textField(title)` | Text Field |
| `.textArea(title)` | Text Area |
| `.checkbox(title)` | Checkbox |
| `.tab(title)` | Tab |
| `.menu(title)` | Menu |
| `.menuItem(title)` | Menu Item |
| `.list(title)` | List |
| `.table(title)` | Table |
| `.row(title)` | Row |
| `.cell(title)` | Cell |
| `.group(title)` | Group |
| `.dialog(title)` | Dialog |
| `.link(title)` | Link |
| `.webArea(title)` | Web Area (Electron/Chromium web content) |
| `.heading(title)` | Heading (web content) |
| ... | [and more](client/src/elements.ts) |

For roles without a shorthand, use `.locator()`:

```ts
app.locator({ role: "color_well", identifier: "bg-color" });
```

All locator methods accept an optional `identifier` for matching by AX identifier:

```ts
app.button(undefined, { identifier: "submit-btn" });
```

### Terminal methods

```ts
await locator.click();                    // Press the element
await locator.fill("text");              // Set text value
await locator.waitFor();                 // Wait for element to appear
await locator.getInfo();                 // Get role, title, value, enabled, focused
await locator.getText();                 // Get value or title
await locator.isEnabled();               // Check enabled state
await locator.isFocused();               // Check focus state
```

All actions auto-wait for the element to appear (default 30s timeout):

```ts
await locator.click({ timeout: 5000 }); // 5 second timeout
```

`click` and `fill` accept a `strategy` to control how the action is applied — useful for
Electron/web content (see [Electron apps](#electron-apps)):

```ts
await locator.click({ strategy: "mouse" });    // "auto" (default) | "ax" | "mouse"
await locator.fill("text", { strategy: "keyboard" }); // "auto" (default) | "ax" | "keyboard"
```

The mouse fallback briefly activates and raises only the target window, posts the
click, then restores the previous app, focused window, and cursor. If the target
was minimized, it is re-minimized afterward. To reduce the chance of stealing
focus mid-keystroke, wait for a quiet moment first (the wait is capped at 5s):

```ts
await locator.click({ strategy: "mouse", waitForIdleMs: 500 });
```

### Inspecting the UI tree

```ts
const tree = await app.queryTree({ maxDepth: 3 });
console.log(tree);
```

Output (indented text format, designed for LLM consumption):

```
[window "Finder"] h:h_0
  [toolbar] h:h_1
    [button "Back"] h:h_2
    [button "Forward"] h:h_3
  [scroll_area] h:h_4
    [outline] h:h_5
      [row "Applications"] h:h_6
      [row "Desktop"] h:h_7
```

Also available as JSON:

```ts
const json = await app.queryTree({ format: "json", maxDepth: 5 });
```

### Keyboard input

```ts
await app.pressKey("return");
await app.pressKey("a", ["cmd"]);          // Cmd+A (select all)
await app.pressKey("z", ["cmd", "shift"]); // Cmd+Shift+Z (redo)
await app.pressKeys([
  { key: "l", modifiers: ["cmd"] },        // Focus address bar / location field
  { key: "a", modifiers: ["cmd"], delayMs: 75 },
  { text: "https://example.com" },
  { key: "return" },
]);
```

Supported keys: `a`–`z`, `0`–`9`, `f1`–`f12`, `return`, `tab`, `escape`, `space`, `delete`, `up`, `down`, `left`, `right`, and common symbols.

Modifiers: `cmd`, `shift`, `alt` (`option`), `ctrl`.

### Screenshots

```ts
const png = await app.screenshot(); // Returns a Buffer
await fs.writeFile("capture.png", png);
```

Uses ScreenCaptureKit for high-fidelity window capture. macOS will prompt for Screen Recording permission on first use.

Screenshot and OCR both have live regression coverage in the packaged
test-harness suite and the MCP-only demo.

### Listing apps

```ts
const client = new MacbethClient();
const apps = await client.listApps();
// [{ name: "Finder", pid: 386, runtime: "native" },
//  { name: "Slack", pid: 1234, runtime: "electron" }, ...]
```

`list_apps` reports each process as `native`, `electron`, or `unknown`. Both native
AppKit apps and Electron/Chromium apps are fully supported through the same client
and MCP APIs (see [Electron apps](#electron-apps) for runtime-specific details).

### Electron apps

macbeth automates Electron apps (Slack, VS Code, Discord, Notion, Figma desktop, …)
with the same locator API as native AppKit apps. Chromium keeps its accessibility
tree disabled until it detects an assistive-technology client, so on connect macbeth
sets the documented `AXManualAccessibility` attribute to switch the tree on, then
waits for the web content to appear before returning.

```ts
const slack = await client.connect("Slack");
// The web content (an AXWebArea) is ready by the time connect() resolves.
await slack.window("Slack").webArea().textField().fill("hello team");
await slack.window("Slack").webArea().button("Send").click();
```

**What works**

- The full web-content accessibility tree (`web_area`, `link`, `button`, `heading`,
  `text_field`, `text_area`, `checkbox`, lists, tables, …) via `query_tree` and locators.
- `click` and `fill` with automatic fallbacks tuned for web content (below).
- Screenshots, OCR (`extract_text`), and menu-bar automation, same as native apps.

**Readiness delay** — after `AXManualAccessibility` is set, Chromium takes a short,
non-deterministic moment (usually <1s) to build the tree. `connect()` polls for it up to
a timeout you can tune:

```ts
const app = await client.connect("Slack", { readyTimeoutMs: 5000 }); // default 3000
```

If the front window legitimately has no web content, `connect()` proceeds anyway rather
than failing — native fallback behavior is preserved.

**Action strategies** — web content has two quirks the default `"auto"` strategy handles:

- `fill`: a raw AX value write can succeed while the framework (React, etc.) never sees an
  input event, leaving app state stale. On Electron, `"auto"` synthesizes real keystrokes
  so the app registers the input. Force it with `strategy: "keyboard"`, or force a plain
  AX write with `strategy: "ax"`.
- `click`: the pressable action sometimes lives on an adjacent node, and canvas-heavy UIs
  expose geometry but no actions. `"auto"` tries `AXPress` on the element and its
  neighbours, then falls back to a synthetic mouse click at the element's center. The
  fallback briefly surfaces only the target window and restores the previous app/window
  and cursor afterward. Force either end with `strategy: "ax"` or `strategy: "mouse"`.

**Known limitations**

- The AX tree is not the DOM. You get roles, titles, values, and geometry — not arbitrary
  DOM attributes, CSS, or `data-*` fields.
- Electron re-renders can invalidate element handles sooner than the 5-minute TTL. Locator
  chains re-resolve automatically; raw `query_tree` handles (`h_N`) should be re-fetched if
  they go stale.
- For richer needs (evaluating JS, reading DOM attributes), launch the app with
  `--remote-debugging-port` and drive it over the Chrome DevTools Protocol — that's outside
  macbeth's scope.

An end-to-end integration test against a real Electron app lives in
[`client/test-electron/`](client/test-electron/) (`npm run test:electron`, macOS-only).

### Lifecycle

For simple scripts, `connect()` is all you need — the process exits cleanly when the work is done, and the daemon stays warm for the next run.

For long-running programs or when you want explicit control, use `MacbethClient`:

```ts
const client = new MacbethClient();
const app = await client.connect("Finder");
await app.button("Back").click();
await client.close(); // disconnects and shuts down daemon
```

`MacbethClient` supports `await using` for automatic cleanup:

```ts
{
  await using client = new MacbethClient();
  const app = await client.connect("Finder");
  await app.button("Back").click();
} // client.close() called automatically
```

### Writing tests

macbeth works with any test runner. Here's an example with vitest:

```ts
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { MacbethClient, AppHandle } from "macbeth";

describe("TextEdit", () => {
  let client: MacbethClient;
  let app: AppHandle;

  beforeAll(async () => {
    client = new MacbethClient();
    app = await client.connect("TextEdit");
  });

  afterAll(async () => {
    await client.close();
  });

  it("should fill a text field", async () => {
    await app.window("Untitled").textField().fill("Hello");
    const text = await app.window("Untitled").textField().getText();
    expect(text).toBe("Hello");
  });

  it("should click a button", async () => {
    const btn = app.window("Untitled").button("Submit");
    await btn.click();
    expect(await btn.isEnabled()).toBe(true);
  });
});
```

## MCP server

macbeth includes an MCP server so LLM agents (Claude, etc.) can automate macOS apps through tool calls.

The published npm package ships a **prebuilt, notarized universal daemon** — there is no build step, and no Swift toolchain is required. `npx macbeth` downloads the package and starts the MCP server over stdio, so the same command works as a universal MCP entry point for any agent that speaks the [Model Context Protocol](https://modelcontextprotocol.io).

### Install (one-liner)

**Claude Code** — register the server from your terminal:

```bash
claude mcp add macbeth -- npx -y macbeth
```

That's the whole install. `npx -y` fetches `macbeth` on first launch (and caches it), the daemon binary is bundled, and macOS prompts for Accessibility the first time a tool runs.

<details>
<summary>Other agents / manual config</summary>

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

To pin a version instead of always taking the latest, use `npx -y macbeth@0.2.1` (or install globally with `npm i -g macbeth` and use `"command": "macbeth"`).

</details>

### Verify it works

After registering, confirm the two macOS permissions and daemon are healthy:

```bash
npx macbeth doctor   # prints Accessibility + Screen Recording status, exits non-zero if AX is denied
```

Then ask your agent to run this **smoke-test prompt**:

> Using the macbeth MCP tools, call `list_apps` and tell me which apps are running. Then `connect_app` to Finder, `query_tree` its front window, and report the first few elements you see.

A healthy install returns a list of running apps and a small accessibility tree for Finder. If any step fails — the tools don't appear, `list_apps` errors, or the tree comes back empty — see **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)**.

### Updating

macbeth can update itself to the most recent signed GitHub release:

```bash
npx macbeth update          # install the latest release
npx macbeth update --check  # report whether an update is available, without installing
```

`update` queries the latest release of [`wende/macbeth`](https://github.com/wende/macbeth/releases),
compares it against the installed version, and — when a newer one exists —
installs the notarized package attached to that release via `npm install -g`
(falling back to the npm registry if the release has no packaged tarball). Set
`MACBETH_UPDATE_REPO` to point the check at a fork.

### Available tools

| Tool | Description |
|---|---|
| `list_daemon_methods` | List registered daemon RPCs for MCP parity checks |
| `begin_activity` / `end_activity` | Explicitly bracket external computer-control work with the interaction glow |
| `list_apps` | List running macOS apps |
| `connect_app` | Connect to an app by name or PID |
| `query_tree` | Get the accessibility tree as text or JSON |
| `get_element` | Find an element by query or handle and return its properties |
| `dump_attributes` | Dump all AX attributes for an element handle |
| `read_form` | Read form-like controls from an app or subtree |
| `click` | Click a UI element (auto-waits) |
| `fill` | Set a text field's value (auto-waits) |
| `wait_for` | Wait for existence, value, change, or enabled state |
| `press_key` | Activate the target app, then send keyboard input |
| `press_keys` | Activate the target app, then send a sequence of key presses |
| `screenshot` | Capture a window screenshot with a visible focus/scan/snap animation |
| `extract_text` | OCR an app window or supplied PNG data |
| `pin_handle` / `unpin_handle` | Control element-handle expiry |
| `list_menu_bar` / `select_menu_item` | Inspect and select native menu items |
| `run_applescript` | Execute AppleScript or JXA through the daemon, classified as interactive or read-only |
| `list_shortcuts` / `run_shortcut` | Inspect and run Apple Shortcuts |
| `list_skills` / `load_skill` / `run_skill_script` | Discover and run bundled app workflows |

### Skills

Drop a `SKILL.md` file into `skills/<name>/` to teach agents how to automate specific apps or workflows. Skills are loadable via the `list_skills` and `load_skill` MCP tools.

Bundled skills include Calendar, Contacts, Mail, Maps, Messages, Music, Notes, Reminders, Safari, System Settings, Logic Pro, and an [Electron](skills/electron/SKILL.md) guide covering web-area trees, fill/click strategies, and common gotchas.

## Architecture

```
macbeth/
├── daemon/                 # Swift daemon (macbethd)
│   ├── Sources/macbethd/
│   │   ├── main.swift      # Entry point, arg parsing, signal handling
│   │   ├── Transport/      # Unix socket server, client connections
│   │   ├── JSONRPC/        # JSON-RPC 2.0 message types, dispatcher
│   │   ├── AX/             # Accessibility API wrappers
│   │   │   ├── HandleTable.swift      # Opaque handle management (5-min TTL)
│   │   │   ├── AppConnection.swift    # App connection + fuzzy name matching
│   │   │   ├── ElectronSupport.swift  # AXManualAccessibility + web-area readiness
│   │   │   ├── TreeWalker.swift       # Recursive AX tree traversal
│   │   │   ├── TreeSerializer.swift   # Text + JSON tree output
│   │   │   ├── ElementQuery.swift     # Query path resolution
│   │   │   ├── ElementValidity.swift  # Stale-handle detection (Electron re-renders)
│   │   │   ├── SafeMouseClick.swift   # Coordinate click with app/window restore
│   │   │   └── KeyCodes.swift         # Key name → CGKeyCode mapping
│   │   ├── Methods/        # RPC method implementations
│   │   │   ├── Click.swift, Fill.swift, PressKey.swift
│   │   │   ├── Screenshot.swift, WaitFor.swift, ExtractText.swift
│   │   │   └── ListApps.swift, ConnectApp.swift, ...
│   │   └── Glow/           # GlowIndicator: drives the macbeth-glow helper
│   ├── Sources/GlowProtocol/ # Shared IPC message + debounce logic (testable)
│   ├── Sources/macbeth-glow/ # AppKit helper: renders window interaction overlays
│   └── Tests/
├── client/                 # TypeScript client + MCP server
│   ├── src/
│   │   ├── index.ts        # Public API
│   │   ├── client.ts       # MacbethClient + AppHandle
│   │   ├── elements.ts     # Locator (chainable, immutable)
│   │   ├── rpc.ts          # JSON-RPC client over Unix socket
│   │   ├── daemon.ts       # Daemon process management
│   │   ├── mcp.ts          # MCP server
│   │   └── types.ts        # TypeScript interfaces
│   ├── test-electron/      # End-to-end Electron fixture + runner
│   └── bin/macbeth.mjs     # npx entry point
├── protocol/               # Shared JSON-RPC schema definitions
├── skills/                 # Bundled app workflows (SKILL.md + scripts)
├── test/                   # Test apps & fixtures
│   ├── test-harness/       # Packaged AppKit test harness source
│   ├── testapp-minimal/    # Minimal Swift CI harness
│   └── electron-testapp/   # Electron demo app for automation
├── assets/                 # Logo and media
└── scripts/
    ├── build-daemon.sh     # Build universal binary
    └── demo-mcp.mjs        # MCP feature demo (native + Electron)
```

### Key design decisions

- **Protocol**: JSON-RPC 2.0 over Unix domain socket, newline-delimited JSON framing. Fast, no HTTP overhead, no port conflicts.
- **Handles**: UI elements are referenced by opaque string IDs (`h_0`, `h_1`, ...) stored in a server-side handle table with 5-minute TTL. This avoids serializing AXUIElement references across process boundaries. Locators re-resolve on `stale-element` errors from Electron re-renders.
- **Auto-wait**: All action methods (click, fill) poll for the target element until it appears or the timeout expires. No manual waits needed.
- **Locators are lazy**: Building a locator chain (`app.window('X').button('Y')`) does nothing — the query is only resolved when you call a terminal method.
- **Electron without DOM access**: Enable Chromium's AX tree with `AXManualAccessibility` (never `AXEnhancedUserInterface`, which resizes windows). Prefer AX actions; synthesize keystrokes or safe mouse clicks only when the web content needs real input events.
- **Daemon lifecycle**: The TypeScript client auto-spawns the daemon as a subprocess and shuts it down on close. No background service to manage.
- **Zero external Swift dependencies**: The daemon uses only Foundation, ApplicationServices, ScreenCaptureKit, CoreGraphics, and Vision.
- **Swift 6 strict concurrency**: Full Sendable compliance. AXUIElement is wrapped in `@unchecked Sendable` (safe — it's a mach port).

## Interaction indicator

Whenever an MCP tool or daemon method addresses an app window, Macbeth places a
subtle glow and outline around that exact window. Click/fill actions add a
synthetic presentation pointer, and screenshots add a brighter scan/snap, so it
is apparent which app is being controlled without lighting the entire display.

How it works:

- The daemon has no AppKit run loop, so the overlays are rendered by a tiny helper
  process (`macbeth-glow`) that the daemon spawns lazily on the first
  interaction and reuses afterwards. Commands travel over the helper's stdin as
  newline-delimited JSON (`activate`, `deactivate`, window-focus, capture, and
  shutdown messages).
- Activity scopes are reference-counted across overlapping MCP and daemon work.
  MCP-side operations use tokenized `begin_activity`/`end_activity` RPCs so a
  nested action cannot turn off another action's glow.
- Window-local glow is shown only when the explicitly targeted window is the
  system-wide focused frontmost window at the start of the operation. Macbeth
  can still inspect or manipulate background windows, but does so without a
  misleading outline, presentation pointer, or capture animation. If a
  previously outlined app loses frontmost (user switch, harness
  backgrounding, etc.), `macbeth-glow` drops that outline immediately.
  Paths that must foreground the target (`press_key` / `press_keys`, keyboard
  `fill`, Electron auto-fill) re-present the outline **after** activation so
  chrome tracks the window the user is now looking at.
- Addressing an app through MCP places a quiet, click-through violet outline
  and inward edge glow around the controlled window. Every window is keyed by
  its stable process/window identity, so several windows of the frontmost app
  can remain outlined simultaneously and moving one updates only its own
  overlay. Outlines never span apps: whichever app is frontmost owns the only
  visible chrome, and the previous app's outlines are dropped when it loses
  frontmost. The
  outline and inward glow remain visually static while present. Each
  window has an independent lifetime: after its final overlapping operation
  ends, its outline remains fully visible for 400ms and then fades over 100ms.
  Re-addressing an already-visible window refreshes only that deadline—it never
  restarts fade-in, changes opacity, or pulses the border. An interrupted
  fade-out reverses from the opacity currently visible on screen.
- Click and fill RPCs move a violet-tinted synthetic pointer to the resolved AX
  element before acting. Keyboard-only operations deliberately leave it at the
  last honest pointer target because synthetic focused AX nodes often have no
  meaningful screen geometry. The pointer makes a short first approach from a
  synthetic offset near the first
  target, then preserves its own last position and eases between later
  targets—even after it briefly fades. It shows a click ring or text caret on
  arrival, uses a subtle violet backing halo for contrast, and never reads or
  moves the user's real cursor. Its fade is interruptible, which keeps it
  continuous across closely spaced recorded-demo operations.
- Window screenshots and app-window OCR intensify that perimeter with a brighter
  rounded frame, one scan from the top through the bottom of the target, and a
  longer completion snap. The scan holds at the bottom while capture completes
  and cannot wrap into a partial second pass. The snap expands the border and
  holds its light wash before dissolving. These overlays are owned by
  `macbeth-glow` and use `sharingType = .readOnly`: Macbeth's own single-window
  screenshots exclude them, while an external screen recording can still show
  the animation.
- The indicator is entirely best-effort: if the helper can't start or crashes,
  the daemon logs a warning and keeps working — automation is never blocked.

Configuration (environment variables read by the daemon, plus the `--no-glow`
flag):

| Variable | Default | Description |
| --- | --- | --- |
| `MACBETH_GLOW` | `1` | Set to `0`/`false`/`off`/`no` to disable the indicator entirely (same as `--no-glow`). |
| `MACBETH_GLOW_COLOR` | `#8B3342` | Accent color as hex (`#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA`). |
| `MACBETH_GLOW_DEBOUNCE_MS` | `400` | Refreshable fully-visible hold in milliseconds between the final activity ending and the 100ms window-highlight fade. |
| `MACBETH_GLOW_HELPER` | — | Explicit path to the `macbeth-glow` binary (otherwise discovered next to `macbethd`). |

Each controlled-window glow remains intact for its own 400ms hold, then performs
an interruptible 100ms fade and is ordered out. Capture animation timers exist
only while capture is in progress. All presentation layers are click-through
and owned by the helper process, so target-window screenshots remain clean.

## Permissions

macbeth needs two macOS permissions:

1. **Accessibility** — required for all UI automation. macOS will prompt on first use, or you can grant it in System Settings → Privacy & Security → Accessibility.

2. **Screen Recording** — required only for screenshots. If not granted when a screenshot is requested, macbeth will automatically open the correct System Settings pane.

## Requirements

- macOS 14 (Sonoma) or later
- Node.js 20+
- Swift 6.0+ (for building from source)

## macOS CI prototype (experimental)

The workflow at
[`.github/workflows/macos-accessibility-prototype.yml`](.github/workflows/macos-accessibility-prototype.yml)
is an experimental prototype that tries to prove Macbeth can be driven
end-to-end from a GitHub-hosted `macos-15` runner with **no human
interaction**. It is intentionally separate from `tests.yml` and is
opt-in via `workflow_dispatch`.

### How to trigger

1. Push the branch containing this workflow.
2. In GitHub, go to **Actions → macOS Accessibility Prototype → Run workflow**.
3. Optionally toggle `skip_grant_script` (to re-run only the test phase)
   or `grant_verbose` (to dump extra TCC schema info).
4. Wait for the run to finish. Both a passing and a failing run are
   useful — the diagnostic artifact is uploaded either way.

### What it tests

The workflow:

1. Builds `macbethd` and stages it under `$RUNNER_TEMP`.
2. Runs `macbethd --check-permissions` to record the baseline (almost
   always denied on a fresh runner).
3. Calls `scripts/ci-grant-macos-permissions.sh` to write
   Accessibility + Screen Recording rows into the user TCC database by
   cloning an existing `/bin/bash` row.
4. Re-runs `macbethd --check-permissions` to verify the grant took.
5. Builds and launches a minimal Swift test harness
   (`test/testapp-minimal/`) with one window, one text field, one button,
   and one status label.
6. Runs `scripts/ci-e2e-test.mjs`, which uses the real Macbeth stack
   (`MacbethClient` → daemon → AX) to:
   - connect to the harness,
   - find its window,
   - read the text field's initial value,
   - fill a new value,
   - click the button,
   - verify the status label changed.

### Why it manipulates TCC

macbeth needs Accessibility and Screen Recording entitlements. On a
fresh `macos-15` runner neither is granted, and there is no
authenticated user to click **Allow** in System Settings. The script
`scripts/ci-grant-macos-permissions.sh` writes rows directly into the
**user** TCC database (`~/Library/Application Support/com.apple.TCC/TCC.db`).
Both `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()` are
evaluated against the user DB, so this is sufficient for the prototype.
The system TCC DB on `/Library/Application Support/com.apple.TCC/TCC.db`
is on the signed system volume and cannot be modified; the script
detects this and warns instead of failing.

### ⚠️ Why it must not run on a developer workstation

The TCC injection script:

- Inspects and rewrites `~/Library/Application Support/com.apple.TCC/TCC.db`.
- Stops and restarts `tccd`.
- Clones TCC entries from `/bin/bash`.

Running it on a personal machine leaves dangling TCC rows for the
macbeth binary that can confuse other apps and Apple's tamper
detection. **It is safe only inside ephemeral GitHub Actions
`macos-15` runners**, where the entire VM is discarded after the job.
The script's `README` and the workflow file both state this. If you
want to run Macbeth on your own machine, grant permissions normally
through System Settings — do not run this script.

### Interpreting failure modes

The diagnostic artifact (`macbeth-ci-prototype-diag`) includes:

| File                              | What it tells you |
| --------------------------------- | ----------------- |
| `env.txt`                         | macOS version, console user, GUI session — rules out "no user logged in". |
| `tcc-inspect.txt`                 | Whether the user TCC DB is reachable, whether rows were cloned from `/bin/bash`. |
| `preflight-before.txt`            | Baseline permissions — almost always DENIED on a fresh runner. |
| `grant-script.log`                | Full TCC injection output — see the row dump before/after. |
| `preflight-after.txt`             | Permissions after injection. If still DENIED → grant failed. |
| `harness.stdout.log` / `.stderr.log` | Test harness output — crashes here mean Swift/AppKit failed to launch. |
| `e2e-test.log`                    | The end-to-end test trace. The last error tells you whether it was connect-app, get_element, fill, click, or assertion. |
| `post-run.txt`                    | Final TCC rows + harness still alive? |
| `result.json`                     | Parsed outcome (`pass` / `fail` + payload). |

Likely failure points, in order of probability:

1. **`--check-permissions` stays DENIED** — the TCC write was rejected
   or the schema changed. Check `grant-script.log` for the row dump.
2. **System Settings / loginwindow not running** — `env.txt` will show
   a non-graphical session. `macbeth` requires a logged-in GUI user.
3. **Harness crashes at launch** — usually because no WindowServer is
   available. macos-15 runners usually do have a GUI session, but
   some self-hosted configurations don't.
4. **AX queries return empty** — `connect_app` succeeded but the
   harness's window is invisible to AX. This usually means
   Accessibility is granted only to the wrong executable identity
   (path mismatch between the grant target and the running daemon).
5. **`fill` or `click` errors** — Accessibility is granted but
   `AXUIElementPerformAction` is blocked. This is rare on a fresh
   runner; usually it means a relaunch of `tccd` is needed.
6. **Status label assertion fails** — the harness ran but the click
   didn't trigger the action. Verify `harness.stdout.log` for the
   `ci-harness-ready` marker and inspect the AX tree manually with
   `client/bin/macbethd --socket-path <sock>` + `query_tree`.

The prototype is allowed to conclude either way. The point of the
workflow is to produce *evidence*, not to pass.

## License

MIT
