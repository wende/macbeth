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

To pin a version instead of always taking the latest, use `npx -y macbeth@0.2.1` (or install globally with `npm i -g macbeth` and use `"command": "macbeth"`).

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

> Using the macbeth MCP tools, call `list_apps` and tell me which apps are running. Then `connect_app` to Finder, `query_tree` its front window, and report the first few elements you see.

A healthy install returns a list of running apps and a small accessibility tree for Finder. If any step fails — the tools don't appear, `list_apps` errors, or the tree comes back empty — run `npx macbeth doctor` and paste its fix block to your agent, or see **[TROUBLESHOOTING.md](../TROUBLESHOOTING.md)**.

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
