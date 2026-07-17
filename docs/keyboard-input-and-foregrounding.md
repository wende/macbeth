# Keyboard input and foregrounding

Macbeth can inspect application accessibility trees and set many control values
while an app remains in the background. Its `fill` operation uses those
Accessibility APIs directly, so it does not need to take focus.

`press_key` and `press_keys` are different: they send ordinary macOS keyboard
events. macOS routes those events to the active application, rather than to an
arbitrary background window. Macbeth therefore activates the target app before
delivering keyboard input. This ensures keystrokes reach the intended window
instead of the application the user is currently using. The same applies to
`fill` when it falls back to (or is forced into) keyboard synthesis — including
Electron auto-fill. After that intentional activation, the interaction outline
is restored on the now-frontmost window so the chrome matches what the user is
looking at.

## Test-harness implication

The local GUI suite keeps real keyboard delivery separate from its normal
background-friendly checks:

```sh
# Standard local GUI suite: does not intentionally foreground the harness.
MACBETH_GUI_TESTS=1 npm run test:gui

# Includes live `press_key` / `press_keys` coverage: foregrounds the harness.
MACBETH_GUI_TESTS=1 MACBETH_GUI_KEYBOARD_TESTS=1 npm run test:gui
```

Use `fill` for background-safe text entry tests. Enable the keyboard suite only
when testing physical key delivery, shortcuts, focus traversal, or other
behavior that depends on real keyboard events.

## MCP demo foregrounding suite

A separate opt-in suite walks every public step from `scripts/demo-mcp.mjs`
through the MCP server. For each action it:

1. Starts the native (and Electron) demo fixtures
2. Explicitly backgrounds the target fixture (restores a sentinel frontmost app)
3. Invokes the same MCP tool the demo uses
4. Asserts the fixture is **still not frontmost** when the tool returns
5. Asserts **no `macbeth-glow` target outline** appeared while the fixture was
   backgrounded (via `scripts/list-glow-outlines.swift` / CGWindowList). Outline
   is only supposed to show when the targeted window is already the system-wide
   focused frontmost window at the start of the operation.

```sh
# Requires Accessibility + Screen Recording. Not part of the default green GUI suite.
MACBETH_GUI_FOREGROUND_TESTS=1 npm run test:gui:foreground
```

The invariants are intentional: MCP automation should not leave the target
window frontmost, and should not draw a misleading outline on a background
window. A bare MCP `begin_activity` / glow `activate` only re-arms an existing
outline when that outline still belongs to the system frontmost app — so a
backgrounded fixture cannot keep a stale outline alive across activity scopes.
When the system frontmost app changes, `macbeth-glow` also dismisses any
outline whose owning process is no longer frontmost (so harness
`sendToBackground` / user app switches clear residual chrome).
Actions that synthesize keyboard events (`press_key`, `press_keys`, `fill` with
`strategy: "keyboard"`, Electron auto-fill) currently activate the app so HID
events land correctly, so those cases are expected to fail the frontmost check
until that behavior changes. Mouse-strategy clicks briefly raise the window and
then restore the previous frontmost app — they should pass the frontmost check
if restoration works.
