---
name: macbeth
description: How to drive macOS apps with Macbeth MCP tools — discovery, locators, actions, menus, screenshots/OCR, handles, and fallbacks
---

# Macbeth — Computer Use for macOS

Use this skill whenever you automate a Mac app through Macbeth MCP tools. App-specific skills (Safari, Mail, Electron, …) add quirks on top of this baseline — load those after this one when the target app has one.

Call `load_skill` with **no arguments** (or `name: "macbeth"`) to reload these instructions.

## Mental model

1. **Discover** — `list_apps` / `list_windows` / `query_tree`
2. **Act** — `click` / `fill` / `select_menu_item` / `wait_for`
3. **Verify** — `get_element` / `query_tree` / `screenshot` / `extract_text`
4. **Fall back** — menus → keyboard → screenshot/OCR when Accessibility is thin

Prefer structured Accessibility actions over screenshots and keystrokes. Prefer menus over `press_key` (menus do not steal focus).

## Output format

Tool **results** are YAML; tool **arguments** remain JSON (MCP input schemas are JSON Schema). Read fields by key path, not by line position — paths and titles never get hard-wrapped.

## Permissions

- **Accessibility** — required for almost everything. If every app is not-connectable with AX `-25211`, tell the user to grant Accessibility to the host that launched Macbeth, then restart the agent.
- **Screen Recording** — only for `screenshot` and window-based `extract_text`. OCR of supplied PNG `data` does not need it.
- Diagnose with `npx macbeth doctor` in a terminal when tools fail mysteriously.

## First moves

```jsonc
// What is running and connectable?
{ "name": "list_apps" }

// Is app X open, and what windows does it show? (no AX connect required)
{ "name": "list_windows", "arguments": {} }
{ "name": "list_windows", "arguments": { "app": "Unity" } }

// Menu-bar / LSUIElement apps (Übersicht, Raycast, iTerm2) are omitted from
// list_apps. Discover them with list_windows, then pass ownerName or ownerPid.

// Inspect UI (connects automatically — no prior connect_app)
{ "name": "query_tree", "arguments": { "app": "Finder", "maxDepth": 5 } }
```

### Do you need `connect_app`?

**No.** Every app-taking tool connects on its own from `app` (fuzzy name, PID, or `h_N` app handle).

Call `connect_app` only to:

- preflight Accessibility reachability
- see how a fuzzy name resolved (`matchKind`, aliases, bundle id, `runtime`)
- warm an Electron tree with a longer `readyTimeoutMs`

Reuse the returned app handle:

```jsonc
{ "name": "connect_app", "arguments": { "name": "Slack", "readyTimeoutMs": 5000 } }
// → "Pass app: \"h_3\" to any other tool…"
{ "name": "query_tree", "arguments": { "app": "h_3" } }
```

## Locators (`query`)

Most action tools take either:

- `query` — a chain of steps, each matching descendants of the previous match (recursive; skip intermediate containers), or
- `handleId` — a raw `h_N` from `query_tree` / `get_element` / `read_form`

Each step may set `role`, `title`, `identifier`, `titlePattern` (regex), and `index` (0-based when several match).

```jsonc
{
  "app": "TextEdit",
  "query": [
    { "role": "window" },
    { "role": "text_area" }
  ]
}
```

```jsonc
{
  "app": "Safari",
  "query": [
    { "role": "window" },
    { "role": "web_area" },
    { "role": "link", "titlePattern": "Sign.?in", "index": 0 }
  ]
}
```

Common roles: `window`, `button`, `text_field`, `text_area`, `checkbox`, `radio`, `menu`, `menu_item`, `toolbar`, `scroll_area`, `table`, `row`, `cell`, `group`, `dialog`, `link`, `heading`, `web_area`, `static_text`, `slider`, `pop_up_button`.

Always `query_tree` before inventing locators. Keep `maxDepth` modest (4–6) on huge trees; raise it only for the subtree you care about. When a `query_tree` result shows a `[truncated: …] re-query with handleId h_X` marker, pass that `handleId` back with a higher `maxNodes` to drill into the named subtree (root resets to depth 0 under the handle, so the same `maxDepth` reaches deeper).

## Actions

| Goal | Tool | Notes |
|---|---|---|
| Click a control | `click` | Auto-waits. `strategy`: `auto` (default) \| `ax` \| `mouse` |
| Set a text field | `fill` | Auto-waits. `strategy`: `auto` \| `ax` \| `keyboard` |
| Wait for UI | `wait_for` | `exists` (default), `value_equals`, `value_changes`, `enabled` |
| Read one element | `get_element` | role, title, value, enabled, focused |
| Read form controls | `read_form` | Labels + values for a panel/subtree |
| Native menu | `select_menu_item` | `menuPath: ["File", "Save"]` — no focus steal |
| Compact menus only | `list_menu_bar` | Usually unnecessary — `query_tree` already includes menus |
| Keystroke | `press_key` / `press_keys` | **Last resort** — activates the target app |

### Click / fill strategies

- Leave `strategy` unset (`auto`) unless something fails.
- Electron / React fields: `auto` fill synthesizes keystrokes so the framework sees input. If a value “sticks” in AX but the app ignores it, use `"keyboard"`. Avoid forcing `"ax"` on Electron.
- Canvas / geometry-only UIs: `click` with `"mouse"`. Optional `waitForIdleMs` (≤5000) avoids mid-keystroke focus steals.

### Keyboard outcomes

`press_key` / `press_keys` report `outcome`:

- `dispatched` — events entered the system stream (app may still ignore them)
- `attempted` — could not confirm dispatch

Neither proves the app acted. Confirm with `query_tree`, `wait_for`, or `screenshot` — do **not** resend blindly (duplicate keystrokes are worse than an honest caveat).

## Windows, screenshots, OCR

`list_windows` reads the WindowServer catalog (optional `app` filter). Entries include `windowId`, title, owner, frame, on-screen/active/minimized, AX role/subrole when available, `kind`, `capturable`, and `default`.

```jsonc
{ "name": "screenshot", "arguments": { "app": "Finder" } }
{ "name": "screenshot", "arguments": { "app": "Unity", "windowId": 42, "region": { "x": 0, "y": 0, "width": 400, "height": 300 } } }
{ "name": "extract_text", "arguments": { "app": "Unity", "windowId": 42 } }
```

**`windowId` ≠ element handle.** It is a WindowServer ID: no TTL, ignores `pin_handle`, survives daemon restarts, valid until the window closes. Element handles (`h_0`, …) expire.

Default listing hides menu-bar strips and overlays; pass `includeAllSurfaces: true` when a surface you need is missing.

## Handles

- Element handles (`h_N`) are **canonical** — the same element keeps the same id across `query_tree` calls while it lives.
- Idle TTL is **5 minutes** (60 min when pinned), refreshed on every use.
- Pin handles when you'll return to them later rather than immediately: pass `pin: true` to `read_form` (pins every returned field), `query_tree`, or `get_element` — one call, zero extra tool invocations. Use `pin_handle` with `handleIds: [...]` for the decided-later case.
- There is **no `unpin_handle`**: pins are finite and age out on their own.
- Prefer query-based actions (they re-resolve) over caching raw handles, especially in Electron.
- Errors:
  - `stale_handle` — element gone (`expired` / `destroyed` / `recycled` / `app_terminated`). Re-run `query_tree` or re-resolve the query.
  - `unknown_handle` — this daemon never issued the id (typo or prior daemon process). Do not retry the same id; reconnect / re-query.
- App handles from `connect_app` are also `h_N` but address **apps**, not elements. Dead app handles fail with `app_not_found` — reconnect by name/PID.

## AppleScript / JXA and Shortcuts

`run_applescript` takes the script in **`source`** (not `script` or `code`). Language is exactly `"AppleScript"` or `"JavaScript"` (JXA = `"JavaScript"`).

```jsonc
{ "source": "tell application \"Finder\" to get name of every window" }
{ "source": "Application('Finder').windows().map(w => w.name()).join(', ')", "language": "JavaScript" }
```

`timeout` is seconds (default 30, max 300). A timeout fails **that call only** — the MCP server stays healthy; raise `timeout` instead of retrying blindly.

`list_shortcuts` / `run_shortcut` run system Shortcuts (fuzzy name match).

## Thin Accessibility trees

Some apps (Unity Editor panels, custom canvas UIs) expose little more than a window + menu bar. That is a host limitation, not a Macbeth bug.

Reliable order:

1. `select_menu_item` / `list_menu_bar` for menu commands
2. `press_key` for documented shortcuts (then verify)
3. `screenshot` + `extract_text` for on-screen labels
4. `run_applescript` when the app has a real scripting dictionary

`read_form` shines on native Cocoa apps (System Settings, TextEdit, Xcode) with proper AX values — expect empty results on thin trees.

## Electron apps

Load the `electron` skill. Short version: connect may need `readyTimeoutMs`; expect a short empty-tree window; scope queries under `web_area`; keep `fill`/`click` on `auto` unless overriding for canvas or stubborn fields.

## App skills

```jsonc
{ "name": "list_skills" }
{ "name": "load_skill", "arguments": { "name": "Safari" } }
{ "name": "run_skill_script", "arguments": { "skill": "Safari", "script": "open-url.mjs", "args": ["https://example.com"] } }
```

Bundled app skills include Calendar, Contacts, Mail, Maps, Messages, Music, Notes, Reminders, Safari, SystemSettings, LogicPro, and `electron`.

## External computer-use

Macbeth’s own `click` / `fill` / `press_key` / `run_applescript` already show the interaction glow. Only call `begin_activity` / `end_activity` when you drive the Mac through some **other** tool Macbeth cannot see, and always end with the returned token.

## Error reading

Tool errors are often `[error_kind]: message`. Common kinds: `app_not_found`, `element_not_found`, `stale_handle`, `unknown_handle`, `timeout`, `permission_denied`, `menu_item_not_found`, `menu_item_disabled`, `app_busy`. Operation timeouts are not transport failures — other tools keep working.

## Default workflow checklist

1. `list_apps` or `list_windows` to confirm the target exists / is connectable
2. `query_tree` (or `read_form` for native forms) to learn roles and titles
3. `click` / `fill` / `select_menu_item` with query locators
4. `wait_for` or re-query to confirm the effect
5. If AX is empty or degraded → menus → keyboard → screenshot/OCR
6. Load an app skill when one exists for the target
