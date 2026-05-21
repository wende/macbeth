# Macbeth - Playwright for MacOS native apps

Macbeth automates any macOS application through the [Accessibility API](https://developer.apple.com/documentation/accessibility). It provides a TypeScript client with chainable locators, auto-waiting, and screenshot capture — the same patterns you know from Playwright, applied to native macOS UI elements instead of the browser DOM.

It also ships as an MCP server, so LLM agents can drive macOS apps through tool calls.

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

### Listing apps

```ts
const client = new MacbethClient();
const apps = await client.listApps();
// [{ name: "Finder", pid: 386, runtime: "native" },
//  { name: "Slack", pid: 1234, runtime: "electron" }, ...]
```

macbeth auto-detects whether apps are native, Electron, or unknown.

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

### Setup

Add to your Claude Code MCP config (`.mcp.json`):

```json
{
  "mcpServers": {
    "macbeth": {
      "command": "npx",
      "args": ["macbeth"]
    }
  }
}
```

### Available tools

| Tool | Description |
|---|---|
| `list_apps` | List running macOS apps |
| `connect_app` | Connect to an app by name or PID |
| `query_tree` | Get the accessibility tree as text |
| `get_element` | Find an element and return its properties |
| `click` | Click a UI element (auto-waits) |
| `fill` | Set a text field's value (auto-waits) |
| `wait_for` | Wait for an element to appear |
| `press_key` | Activate the target app, then send keyboard input |
| `press_keys` | Activate the target app, then send a sequence of key presses |
| `screenshot` | Capture a window screenshot |

### Skills

Drop a `SKILL.md` file into `skills/<name>/` to teach agents how to automate specific apps or workflows. Skills are loadable via the `list_skills` and `load_skill` MCP tools.

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
│   │   │   ├── TreeWalker.swift       # Recursive AX tree traversal
│   │   │   ├── TreeSerializer.swift   # Text + JSON tree output
│   │   │   ├── ElementQuery.swift     # Query path resolution
│   │   │   └── KeyCodes.swift         # Key name → CGKeyCode mapping
│   │   └── Methods/        # RPC method implementations
│   │       ├── Click.swift, Fill.swift, PressKey.swift
│   │       ├── Screenshot.swift, WaitFor.swift
│   │       └── ListApps.swift, ConnectApp.swift, ...
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
│   └── bin/macbeth.mjs     # npx entry point
├── protocol/               # Shared JSON-RPC schema definitions
├── testapp/                # AppKit test harness
└── scripts/
    └── build-daemon.sh     # Build universal binary
```

### Key design decisions

- **Protocol**: JSON-RPC 2.0 over Unix domain socket, newline-delimited JSON framing. Fast, no HTTP overhead, no port conflicts.
- **Handles**: UI elements are referenced by opaque string IDs (`h_0`, `h_1`, ...) stored in a server-side handle table with 5-minute TTL. This avoids serializing AXUIElement references across process boundaries.
- **Auto-wait**: All action methods (click, fill) poll for the target element until it appears or the timeout expires. No manual waits needed.
- **Locators are lazy**: Building a locator chain (`app.window('X').button('Y')`) does nothing — the query is only resolved when you call a terminal method.
- **Daemon lifecycle**: The TypeScript client auto-spawns the daemon as a subprocess and shuts it down on close. No background service to manage.
- **Zero external Swift dependencies**: The daemon uses only Foundation, ApplicationServices, ScreenCaptureKit, and CoreGraphics.
- **Swift 6 strict concurrency**: Full Sendable compliance. AXUIElement is wrapped in `@unchecked Sendable` (safe — it's a mach port).

## Permissions

macbeth needs two macOS permissions:

1. **Accessibility** — required for all UI automation. macOS will prompt on first use, or you can grant it in System Settings → Privacy & Security → Accessibility.

2. **Screen Recording** — required only for screenshots. If not granted when a screenshot is requested, macbeth will automatically open the correct System Settings pane.

## Requirements

- macOS 14 (Sonoma) or later
- Node.js 20+
- Swift 6.0+ (for building from source)

## License

MIT
