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

> Known limitation: Screenshot and OCR have live regression coverage in the
> packaged test-harness suite, but currently fail locally: Screenshot can time
> out and OCR can close the daemon connection. These failures are documented in
> [BUGS.md](BUGS.md); they are not expected failures and must be fixed before
> the GUI suite can be considered fully passing.

### Listing apps

```ts
const client = new MacbethClient();
const apps = await client.listApps();
// [{ name: "Finder", pid: 386, runtime: "native" },
//  { name: "Slack", pid: 1234, runtime: "electron" }, ...]
```

macbeth auto-detects whether apps are native, Electron, or unknown. Native macOS
apps are supported today. Electron automation is detected but not yet supported;
it remains a planned future feature.

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
│   │   ├── Methods/        # RPC method implementations
│   │   │   ├── Click.swift, Fill.swift, PressKey.swift
│   │   │   ├── Screenshot.swift, WaitFor.swift
│   │   │   └── ListApps.swift, ConnectApp.swift, ...
│   │   └── Glow/           # GlowIndicator: drives the macbeth-glow helper
│   ├── Sources/GlowProtocol/ # Shared IPC message + debounce logic (testable)
│   ├── Sources/macbeth-glow/ # AppKit helper: renders the screen-edge glow
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
├── test-harness/           # Packaged AppKit test harness source
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

## Interaction indicator

Whenever the daemon actively drives the system — AX actions, synthetic keyboard
input, window manipulation, or AppleScript/JXA — it lights a subtle glow hugging
the edges of every attached display, so it's always obvious the machine is being
controlled and windows aren't moving "on their own."

How it works:

- The daemon has no AppKit run loop, so the glow is rendered by a tiny helper
  process (`macbeth-glow`) that the daemon spawns lazily on the first
  interaction and reuses afterwards. Commands travel over the helper's stdin as
  newline-delimited JSON (`{"type":"activate"|"deactivate"|"shutdown"}`).
- One borderless, click-through overlay window per screen floats above normal
  and full-screen content, re-laying-out when displays change. The windows are
  `sharingType = .none` and owned by a separate process, so the glow **never
  appears in screenshots** macbeth captures.
- The violet glow fades smoothly inward from each screen edge, fades in fast
  (~150ms), breathes gently while active (disabled if macOS "Reduce Motion" is
  on), and fades out slowly (~600ms) after a debounce window so a burst of rapid
  actions reads as one continuous glow.
- The indicator is entirely best-effort: if the helper can't start or crashes,
  the daemon logs a warning and keeps working — automation is never blocked.

Configuration (environment variables read by the daemon, plus the `--no-glow`
flag):

| Variable | Default | Description |
| --- | --- | --- |
| `MACBETH_GLOW` | `1` | Set to `0`/`false`/`off`/`no` to disable the indicator entirely (same as `--no-glow`). |
| `MACBETH_GLOW_COLOR` | `#A855F7` | Accent color as hex (`#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA`). |
| `MACBETH_GLOW_DEBOUNCE_MS` | `1500` | Milliseconds to keep the glow alive after the last action (debounce). |
| `MACBETH_GLOW_HELPER` | — | Explicit path to the `macbeth-glow` binary (otherwise discovered next to `macbethd`). |

The helper uses ~0% CPU while idle — all overlay windows are ordered out and no
animation timers run until the next interaction.

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
   (`testapp-minimal/`) with one window, one text field, one button,
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
