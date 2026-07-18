# MCP server

macbeth ships an MCP server so LLM agents can automate macOS apps through tool calls.

## Setup

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

Grant **Accessibility** (and **Screen Recording** for screenshots/OCR). The client auto-spawns `macbethd`; no background service to install.

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
| `list_apps` | List running macOS apps |
| `connect_app` | Connect to an app by name or PID |
| `query_tree` | Accessibility tree as text or JSON |
| `get_element` | Find an element by query or handle |
| `dump_attributes` | Dump all AX attributes for a handle |
| `read_form` | Read form-like controls from an app or subtree |
| `click` | Click a UI element (auto-waits) |
| `fill` | Set a text field value (auto-waits) |
| `wait_for` | Wait for existence, value, change, or enabled state |
| `press_key` | Activate target app, send keyboard input |
| `press_keys` | Activate target app, send a key sequence |
| `screenshot` | Window capture with focus/scan/snap animation |
| `extract_text` | OCR a window or supplied PNG |
| `pin_handle` / `unpin_handle` | Control element-handle expiry |
| `list_menu_bar` / `select_menu_item` | Inspect and select native menu items |
| `run_applescript` | AppleScript or JXA (interactive or read-only) |
| `list_shortcuts` / `run_shortcut` | Inspect and run Apple Shortcuts |
| `list_skills` / `load_skill` / `run_skill_script` | Discover and run bundled app workflows |

## Skills

Drop a `SKILL.md` into `skills/<name>/` to teach agents app-specific workflows. Load via `list_skills` / `load_skill`.

Bundled: Calendar, Contacts, Mail, Maps, Messages, Music, Notes, Reminders, Safari, System Settings, Logic Pro, and [Electron](../skills/electron/SKILL.md) (web-area trees, fill/click strategies, gotchas).

Client API for scripts and tests: [skills/DEVELOPING_MACBETH.md](../skills/DEVELOPING_MACBETH.md). Interaction chrome: [interaction-glow.md](interaction-glow.md).
