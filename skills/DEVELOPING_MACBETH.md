# Developing with Macbeth

Playwright-style TypeScript client for native macOS and Electron apps. For MCP setup and product overview, see the [root README](../README.md).

## Install

```bash
npm install macbeth
```

macOS 14+ required. Accessibility is prompted on first run; Screen Recording is requested only when you take screenshots.

### Build from source

```bash
./scripts/build-daemon.sh   # universal binary → client/bin/macbethd
cd client && npm run build
```

Maintainers: [docs/releasing.md](../docs/releasing.md).

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

Scripts exit when the work is done. The daemon stays warm for fast subsequent runs.

## Connecting

```ts
import { connect, MacbethClient } from "macbeth";

// One app — manages daemon lifecycle automatically
const app = await connect("Finder");

// Full control — reuse client across apps
const client = new MacbethClient({ verbose: true });
const finder = await client.connect("Finder");
const music = await client.connect("Music");
await client.close(); // shuts down daemon
```

`connect()` accepts an app name (fuzzy matched) or a PID.

**The split:** everything app-scoped (`queryTree`, `screenshot`, locators, keyboard input, …) hangs off the `AppHandle` returned by `connect()`, not off `MacbethClient`. The client itself only holds global/cross-app operations — `listApps`, `connect`, `runAppleScript`, `dumpAttributes`, lifecycle (`close`). The one deliberate exception is `client.extractText({ appHandle, ... })`: it stays on `MacbethClient` because it also accepts raw image `data` with no app involved at all, so it can't be a pure `AppHandle` method.

## Locators

Locators are immutable and lazy. No RPC until a terminal method like `.click()` or `.fill()`.

```ts
const submitBtn = app.window("Settings").group("Form").button("Submit");

await submitBtn.click();
await submitBtn.waitFor();
```

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
| `.webArea(title)` | Web Area (Electron/Chromium) |
| `.heading(title)` | Heading (web content) |
| … | [and more](../client/src/elements.ts) |

Roles without a shorthand:

```ts
app.locator({ role: "color_well", identifier: "bg-color" });
```

Optional AX identifier:

```ts
app.button(undefined, { identifier: "submit-btn" });
```

## Terminal methods

```ts
await locator.click();
await locator.fill("text");
await locator.waitFor();
await locator.getInfo();
await locator.getText();
await locator.isEnabled();
await locator.isFocused();
```

Actions auto-wait (default 30s):

```ts
await locator.click({ timeout: 5000 });
```

`click` and `fill` accept a `strategy` (useful for Electron — see below):

```ts
await locator.click({ strategy: "mouse" });              // "auto" | "ax" | "mouse"
await locator.fill("text", { strategy: "keyboard" });    // "auto" | "ax" | "keyboard"
await locator.click({ strategy: "mouse", waitForIdleMs: 500 });
```

The mouse fallback briefly raises only the target window, clicks, then restores the previous app, window, and cursor. Prefer `waitForIdleMs` when avoiding mid-keystroke focus steals (capped at 5s).

## Inspecting the UI tree

```ts
const tree = await app.queryTree({ maxDepth: 3 });
console.log(tree);
```

Indented text (LLM-friendly):

```
[window "Finder"] h:h_0
  [toolbar] h:h_1
    [button "Back"] h:h_2
  [scroll_area] h:h_4
    [outline] h:h_5
      [row "Applications"] h:h_6
```

JSON:

```ts
const json = await app.queryTree({ format: "json", maxDepth: 5 });
```

## Keyboard input

```ts
await app.pressKey("return");
await app.pressKey("a", ["cmd"]);
await app.pressKey("z", ["cmd", "shift"]);
await app.pressKeys([
  { key: "l", modifiers: ["cmd"] },
  { key: "a", modifiers: ["cmd"], delayMs: 75 },
  { text: "https://example.com" },
  { key: "return" },
]);
```

Keys: `a`–`z`, `0`–`9`, `f1`–`f12`, `return`, `tab`, `escape`, `space`, `delete`, arrows, common symbols.

Modifiers: `cmd`, `shift`, `alt` (`option`), `ctrl`.

Keyboard delivery activates the target app. Background-safe text entry: use `fill` (AX path). Details: [docs/keyboard-input-and-foregrounding.md](../docs/keyboard-input-and-foregrounding.md).

## Screenshots

```ts
const png = await app.screenshot(); // Buffer
await fs.writeFile("capture.png", png);

const windows = await app.listWindows();
const settings = windows.find((window) => window.title === "Settings");
if (settings?.capturable) {
  const settingsPng = await app.screenshot({ windowId: settings.windowId });
  await fs.writeFile("settings.png", settingsPng);
}
```

`listWindows()` includes windows hosted by app helper processes and windows on
other macOS Spaces. Listing is read-only and does not activate windows or switch
Spaces. ScreenCaptureKit may return blank content for some off-Space app
windows. Screen Recording permission is prompted on first capture.

## Listing windows

```ts
const client = new MacbethClient();

// Every app that owns a window — no connect, no AX tree walk.
const all = await client.listWindows();
const unityIsOpen = all.some((window) => window.ownerName === "Unity");

// One app and its helper processes.
const unity = await client.connect("Unity");
const unityWindows = await unity.listWindows();

// Menu-bar strips, overlays, and bookkeeping surfaces are filtered out by
// default; ask for them when diagnosing a window you cannot capture.
const everySurface = await client.listWindows({ includeAllSurfaces: true });
```

Each entry: `windowId`, `title`, `ownerName` / `ownerPid` / `bundleId`, `frame`,
`layer`, `onScreen`, `active`, `minimized`, `role`, `subrole`, `kind`,
`capturable`, `default`. `role`, `subrole`, and `minimized` come from the
accessibility API and are `null` when the app exposes no AX window for the
surface.

`windowId` is a WindowServer ID, not an element handle: it has no 5-minute TTL,
`pin_handle` does not apply, and it stays valid until the window closes (a
reopened window gets a new ID). Only `h_N` element handles expire.

## Listing apps

```ts
const client = new MacbethClient();
const apps = await client.listApps();
// [{ name: "Finder", pid: 386, runtime: "native" },
//  { name: "Slack", pid: 1234, runtime: "electron" }, ...]
```

Runtime is `native`, `electron`, or `unknown`.

## Electron apps

Same locator API as native apps. On connect, macbeth sets `AXManualAccessibility`, then waits for web content (default 3s):

```ts
const slack = await client.connect("Slack");
await slack.window("Slack").webArea().textField().fill("hello team");
await slack.window("Slack").webArea().button("Send").click();
```

```ts
const app = await client.connect("Slack", { readyTimeoutMs: 5000 });
```

If the front window has no web content, connect proceeds anyway.

**Strategies (`"auto"` default):**

- **fill** — On Electron, synthesizes keystrokes so React-style state sees real input. Force with `strategy: "keyboard"` or plain AX with `strategy: "ax"`.
- **click** — Tries `AXPress` on the element and neighbours, then a synthetic mouse click at center. Force with `strategy: "ax"` or `strategy: "mouse"`.

**Limits:**

- AX tree ≠ DOM — roles, titles, values, geometry; not CSS or `data-*`.
- Re-renders can stale raw `query_tree` handles (`h_N`); locator chains re-resolve. Re-fetch handles if needed.
- For JS/DOM access, use `--remote-debugging-port` + CDP — outside macbeth.

E2E Electron fixture: [`client/test-electron/`](../client/test-electron/) (`npm run test:electron`, macOS-only). Skill guide: [skills/electron/SKILL.md](electron/SKILL.md).

## Lifecycle

Simple scripts: `connect()` is enough.

Long-running or multi-app:

```ts
const client = new MacbethClient();
const app = await client.connect("Finder");
await app.button("Back").click();
await client.close();
```

`await using`:

```ts
{
  await using client = new MacbethClient();
  const app = await client.connect("Finder");
  await app.button("Back").click();
} // client.close() automatic
```

## Writing tests

Any runner works. Vitest example:

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

### Packaged GUI test harness

```bash
npm run build:test-harness
npm run launch:test-harness
```

Launcher opens in the background so it does not steal focus. Macbeth brings the app forward only for keyboard actions or coordinate-click fallbacks.

Opt-in GUI suite (needs Accessibility):

```bash
./scripts/build-daemon.sh
cd client && npm run build && cd ..
MACBETH_GUI_TESTS=1 npm run test:gui
```

Live keyboard delivery (separate from default suite):

```bash
MACBETH_GUI_TESTS=1 MACBETH_GUI_KEYBOARD_TESTS=1 npm run test:gui
```

Foreground audit (mirrors `demo:mcp` steps):

```bash
MACBETH_GUI_FOREGROUND_TESTS=1 npm run test:gui:foreground
```

### MCP feature demo

```bash
npm run demo:mcp
```

Builds daemon, client, and fixtures; walks fills, clicks, keyboard, screenshots, and OCR with interaction overlays. `--fast` or `--delay-ms 1200` for pace. Requires Accessibility + Screen Recording already granted.

## Related

- [docs/mcp.md](../docs/mcp.md) — MCP tools and skills
- [docs/architecture.md](../docs/architecture.md) — protocol, handles, design
- [docs/interaction-glow.md](../docs/interaction-glow.md) — presentation overlays
- [docs/keyboard-input-and-foregrounding.md](../docs/keyboard-input-and-foregrounding.md)
