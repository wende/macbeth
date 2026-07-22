---
name: electron
description: Automate Electron apps (Slack, VS Code, Discord, etc.) whose UI is Chromium web content exposed through the Accessibility API
---

# Electron App Automation

Electron apps (Slack, VS Code, Discord, Notion, Figma desktop, …) render their UI as
Chromium web content. macbeth automates them the same way it does native apps, with a few
Electron-specific things to know.

## Connect

Connect by name or PID as usual:

```json
connect_app({ "name": "Slack" })
```

On connect, macbeth enables Chromium's accessibility tree (`AXManualAccessibility`) and
waits for the web content to expose descendants. Branded Electron distributions are
recognised even when they rename the Electron framework. `list_apps` reports these apps
with `runtime: electron` and includes declared aliases and bundle IDs.

### Expect a readiness delay

After connecting, Chromium needs a short, non-deterministic moment (usually <1s) to
construct the tree. `connect_app` already polls for this, but if the very first
`query_tree` looks empty (just a window shell), wait briefly and query again — the web
content is still materializing. For slow apps, connect with a longer wait:

```json
connect_app({ "name": "Slack", "readyTimeoutMs": 5000 })
```

## Discover the tree first

Always run `query_tree` after connecting, before building locators — Electron trees vary
a lot between apps and change as the app renders. Web content lives under a `web_area`
node:

```
[window "Slack"] h:h_0
  [web_area] h:h_5
    [button "Send"] h:h_31
    [text_field] h:h_28
    [heading "Threads"] h:h_12
    ...
```

Scope queries to the `web_area` and target elements directly — recursive descent means you
don't need to name every intermediate container:

```json
{ "query": [{ "role": "window" }, { "role": "web_area" }, { "role": "button", "title": "Send" }] }
```

Common web-content roles: `web_area`, `heading`, `link`, `button`, `text_field`,
`text_area`, `checkbox`, `radio`, `list`, `table`, `text`. Note Chromium sometimes exposes
a contenteditable message box as `text_area` rather than `text_field` — check the tree.

## Fill and click: use strategy overrides when `auto` fails

Both `fill` and `click` default to `strategy: "auto"`, which handles web content well. Reach
for an override when auto doesn't do what you expect:

**fill** — `"auto" | "ax" | "keyboard"`
- `auto` (default): on Electron it types the value as real keystrokes so the app's
  framework (React, etc.) registers the input. This is almost always what you want.
- `keyboard`: force keystroke synthesis (e.g. if you scripted `ax` and state went stale).
- `ax`: force a direct AX value write. Fast, but the app may not "see" the change — only
  use when you've confirmed it works for that field.

```json
fill({ "app": "Slack", "query": [{ "role": "web_area" }, { "role": "text_area" }], "value": "hello team", "strategy": "keyboard" })
```

**click** — `"auto" | "ax" | "mouse"`
- `auto` (default): tries `AXPress` on the element and its neighbours, then a synthetic
  mouse click at the element center.
- `mouse`: force a coordinate click — best for canvas-heavy UIs (Figma, drawing surfaces)
  that expose geometry but no press action. Macbeth briefly activates only the owning window,
  then restores the previous app, focused window, and cursor. Add `waitForIdleMs` when avoiding
  a mid-keystroke focus steal matters.
- `ax`: force `AXPress` only.

```json
click({ "app": "Figma", "query": [{ "role": "web_area" }, { "role": "button", "title": "Frame" }], "strategy": "mouse" })
```

## Gotchas

1. **Empty first tree** — if `query_tree` returns just the window with no `web_area`, or a
   `degraded_accessibility` warning says the web area has no descendants, the tree may
   still be building. Wait ~500ms and retry, or reconnect with a larger `readyTimeoutMs`.
   If it remains degraded, follow the returned screenshot/OCR/menu/keyboard fallback.
2. **Stale handles** — Electron re-renders can invalidate element handles quickly. Prefer
   query-based locators (they re-resolve automatically) over holding raw `h_N` handles from
   `query_tree`. If an action fails with a "stale-element" error, re-run `query_tree`.
3. **AX tree ≠ DOM** — you get roles, titles, values, and geometry, not DOM attributes or
   CSS. For that, launch the app with `--remote-debugging-port` and use the Chrome DevTools
   Protocol (out of scope for macbeth).
4. **`fill` looks like it worked but the app ignores it** — you probably used
   `strategy: "ax"`. Switch to `auto` or `keyboard`.

## Workflows

### Send a message in a chat app
1. `connect_app({ name: "Slack" })`
2. `query_tree` to find the message box (`text_area` or `text_field` under `web_area`)
3. `fill` the message box (auto strategy synthesizes keystrokes)
4. `press_key({ app: "Slack", key: "return" })` or `click` the Send button

### Click a toolbar/canvas control
1. `query_tree` to find the control under `web_area`
2. `click` with `strategy: "auto"`; if nothing happens, retry with `strategy: "mouse"`
