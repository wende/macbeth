# Troubleshooting

This guide covers the common failure modes when installing and running the
**macbeth** MCP server. Work top to bottom — the first two steps resolve the
majority of cases.

> **Shortcut:** run `npx macbeth doctor`. When it finds a problem it prints a
> ready-to-paste block — the error, your environment, and a link back here —
> that you can drop straight into your coding agent (Claude Code, Cursor, …) to
> diagnose and fix it. The steps below are the same guidance, for when you'd
> rather do it by hand.

## 1. Run the doctor

```bash
npx macbeth doctor
```

This prints the resolved daemon path and the status of the two macOS
permissions macbeth needs, then exits non-zero if Accessibility is denied:

```
macbeth 0.2.3
daemon: /path/to/macbeth/bin/macbethd

macbethd permission preflight
  executable:     /path/to/macbeth/bin/macbethd
  pid:            12345
  accessibility:  GRANTED
  screen_capture: GRANTED

✓ macbeth is ready — all permissions granted.
```

If a check fails, `doctor` follows the preflight with a framed **paste-to-your-agent**
block containing the error, your environment, and a link back to this guide —
copy it into your agent and let it drive the fix. To resolve it yourself:

- `accessibility: DENIED` → jump to [Accessibility permission](#accessibility-permission-denied).
- `screen_capture: DENIED` → screenshots only; see [Screen Recording](#screen-recording-denied-screenshots-fail).
- `macbethd binary not found` → see [Daemon binary not found](#daemon-binary-not-found).

## 2. Confirm the environment

| Requirement | Check | Notes |
|---|---|---|
| macOS 14 (Sonoma)+ | `sw_vers -productVersion` | Older macOS is unsupported. |
| Node.js 20+ | `node -v` | `npx` ships with Node. |
| A logged-in GUI session | — | macbeth drives the window server; it cannot run over a pure SSH/headless session. |

macbeth is a **macOS-only** package (`"os": ["darwin"]`). `npm install` on
Linux/Windows fails with `EBADPLATFORM` by design.

---

## The MCP tools don't appear in my agent

The agent connects but shows no `macbeth` tools (or "server failed to start").

1. **Test the launch command directly.** The server talks stdio JSON-RPC, so a
   bare run should start and wait (Ctrl-C to exit):

   ```bash
   npx -y macbeth
   ```

   If this errors, the message tells you why (missing Node, bad install, missing
   daemon). Fix that first — the agent runs the exact same command.

2. **Check the config shape.** The command is `npx` and args are `["-y", "macbeth"]`
   with **no extra arguments** — any unrecognized bare word makes the CLI print
   help and exit instead of starting the server. Config file locations:

   - Claude Code (project): `.mcp.json` in the repo root
   - Claude Desktop: `~/Library/Application Support/Claude/claude_desktop_config.json`
   - Cursor: `~/.cursor/mcp.json`

3. **Restart the agent** after editing its MCP config — most clients only read it
   at startup.

4. **First-run latency.** `npx -y macbeth` downloads the package on first use. If
   your client has a short startup timeout, pre-warm the cache once from a
   terminal (`npx -y macbeth` then Ctrl-C), or install globally and point the
   config at the binary:

   ```bash
   npm i -g macbeth
   # then set "command": "macbeth", "args": []
   ```

## Daemon binary not found

```
macbethd binary not found. Searched:
  - .../bin/macbethd
  ...
```

The bundled universal daemon is missing. Usually this means an incomplete
install or a source checkout that was never built.

- **Installed via npm/npx:** reinstall to repair the package.

  ```bash
  npm i -g macbeth        # or remove the npx cache: npx clear-npx-cache
  ```

- **Running from a source clone:** the daemon isn't built yet. Build it, or point
  macbeth at a build you control:

  ```bash
  ./scripts/build-daemon.sh                 # → client/bin/macbethd
  # or, for an ad-hoc build:
  export MACBETH_DAEMON_PATH=/abs/path/to/macbethd
  ```

`MACBETH_DAEMON_PATH` overrides binary discovery entirely and is the escape
hatch when the auto-resolved path is wrong.

## Accessibility permission denied

Symptoms: `doctor` reports `accessibility: DENIED`; `click`, `fill`, and
`read_form` fail; `query_tree` returns an empty or 1–2 node tree for every app.

Accessibility gates **all** UI automation. Grant it to the process that hosts
the daemon:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Enable the app that launches macbeth — this is the **terminal or agent
   process**, not `macbethd` itself (the daemon inherits its parent's TCC
   identity). For Claude Desktop, enable *Claude*; for a terminal-launched
   agent, enable *Terminal* / *iTerm*; for an IDE, enable that IDE.
3. **Fully quit and relaunch** that app — TCC only re-evaluates on a fresh
   launch.
4. Re-run `npx macbeth doctor` to confirm `GRANTED`.

If it flips back to `DENIED` after a macbeth update, macOS may be keying the
grant to a changed binary path — remove the stale Accessibility entry with the
`−` button and re-add the current one.

## Screen Recording denied (screenshots or window OCR fail)

Only the `screenshot` tool and window-based `extract_text` calls need this.
OCR over image data supplied directly to `extract_text` does not. Everything
else works without Screen Recording access.

- Grant in **System Settings → Privacy & Security → Screen Recording**, then
  relaunch the host app.
- macbeth opens the correct pane automatically when a screenshot or window OCR
  request encounters missing permission.

## `list_apps` works but `connect_app` can't find my app

- `connect_app` does **fuzzy** name matching, but the app must be **running and
  have a GUI**. Launch it first.
- Try the exact name from `list_apps`, or pass the **PID** instead of a name.
- Sandboxed helper processes sometimes register under a different name than the
  visible app — check the `list_apps` output for the real entry.
- Macbeth reports declared bundle aliases and how a name resolved. For example, a
  request for `Codex` may resolve to the running `ChatGPT` process through its declared
  alias while retaining bundle ID `com.openai.codex`.

## `query_tree` returns only 3–5 nodes / `read_form` finds nothing

For some apps this is expected, not a bug. Complex non-native hosts (Unity,
some Electron IDEs) expose only the window and menu bar to the Accessibility
API; panel internals are invisible to AX.

- **Electron/Chromium apps** (Slack, VS Code, Discord) need their AX tree
  switched on. macbeth does this on `connect_app` by setting
  `AXManualAccessibility` and waiting for a web area with exposed descendants. Branded
  Electron apps are detected through bundle metadata even when their framework has
  been renamed. If the tree is still thin, the app may need more time — raise
  `connect_app`'s `readyTimeoutMs` (default 3000). `query_tree` reports
  `degraded_accessibility` when the web area remains empty and suggests fallbacks.
- **Unity and similar:** drive them via `list_menu_bar` / `select_menu_item`
  and read on-screen state with `extract_text` (OCR) and `screenshot`. See the
  [AX limitations](CLAUDE.md#ax-limitations-in-complex-apps-unity-electron-ides)
  notes.
- **Native macOS apps** (System Settings, TextEdit, Xcode) should return a full
  tree. If one doesn't, it's almost always the Accessibility permission above.

## `stale-element` errors

Electron re-renders can invalidate an element between resolving it and acting on
it. Locators built through the client re-resolve and retry automatically. If you
are driving raw `h_N` handles from `query_tree`, they carry no query path — the
error tells you to re-run `query_tree` and use the fresh handle.

Handles also expire after **5 minutes** of inactivity. For long-lived
references, `pin_handle` exempts a handle from expiry (and `Locator.scope()`
pins automatically).

## Menu automation or AppleScript times out

- `select_menu_item` and `list_menu_bar` use Accessibility directly and accept either a
  fuzzy app name or PID. They do not require System Events or Automation permission.
- `query_tree` already contains the menu hierarchy. Skip `list_menu_bar` when the needed
  menu path is visible there.
- Arbitrary `run_applescript` calls still use Apple Events, but run in a killable worker
  with a hard timeout. `permission_denied` points to Privacy & Security → Automation;
  `timeout` identifies either the configured deadline or OSA error -1712.
- The deadline is per call and configurable: `run_applescript`'s `timeout` is in seconds
  (default 30, max 300; the daemon clamps to 0.1–300s). Raise it for work that is
  legitimately slow, such as enumerating the Accessibility tree of a dozen apps —
  don't retry the same script at the default budget.
- A timeout stops that script and fails only that call. It is not a server fault: the
  daemon connection stays up, health is unaffected, and unrelated tools such as
  `connect_app` keep working, however many scripts time out in a row. If other tools do
  start failing too, the cause is a transport problem (see the next section), not the
  script deadline.

## The daemon crashed / socket errors

macbeth auto-spawns the daemon and auto-reconnects (re-spawning it) on
connection errors, so transient crashes are usually invisible. When they aren't:

- The socket lives at `$TMPDIR/macbeth-<uid>.sock` (falls back to
  `/tmp/macbeth-<uid>.sock`). A stale socket file is removed before re-spawning.
- After a daemon restart, previously issued handle IDs are invalid — re-obtain
  the app handle and re-query.
- For a deep look, run the daemon by hand with verbose logging and its own
  socket:

  ```bash
  "$(npx macbeth doctor | sed -n 's/^daemon: //p')" --verbose --socket-path /tmp/macbeth-debug.sock
  ```

  `--no-glow` disables the window interaction overlays if they interfere with
  what you're debugging.

## Updating / version mismatch

```bash
npx macbeth version         # installed version
npx macbeth update --check  # is a newer signed release available?
npx macbeth update          # install the latest release
```

`update` pulls the notarized package from the latest
[`wende/macbeth`](https://github.com/wende/macbeth/releases) release. Point the
check at a fork with `MACBETH_UPDATE_REPO=owner/repo`.

## Error code reference

RPC errors surface to the agent as `[error_kind]: message`.

| Kind | Meaning |
|---|---|
| `element_not_found` | The locator matched nothing before timeout. |
| `timeout` | `wait_for`, an auto-wait, or a script deadline expired. Scoped to that one call; the server stays healthy. |
| `permission_denied` | Accessibility (or Screen Recording) not granted — run `doctor`. |
| `app_not_found` | `connect_app` couldn't match a running app. |
| `action_failed` | `AXUIElementPerformAction` was rejected by the app. |
| `menu_item_not_found` / `menu_item_disabled` | Menu path missing or greyed out. |
| `app_busy` | The app was mid-operation; retry. |
| `script_failed` | AppleScript/JXA raised an OSA error. |
| `ax_lookup_failed` | An AX attribute read failed. |

## Still stuck?

Open an issue at <https://github.com/wende/macbeth/issues> and include:

- `npx macbeth version` and `npx macbeth doctor` output
- `sw_vers -productVersion` and `node -v`
- Which agent/client and its `mcpServers` config block
- The failing tool call and the full error text
