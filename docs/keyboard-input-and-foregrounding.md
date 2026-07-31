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

## What a keyboard result can and cannot prove

`press_key` and `press_keys` report how far the input got, using a three-tier
`outcome`:

| Outcome | Meaning |
| --- | --- |
| `attempted` | The events could not be shown to have entered the event stream — no `CGEvent` could be created, the session key-down counter never advanced, or it advanced for only some of the posted events. |
| `dispatched` | Every posted event is accounted for in the system event stream. Whether the target app consumed them is **unknown**. |
| `verified` | The app's observable state changed as a result. **Not produced yet** — reserved for effect verification. |

Alongside the outcome, the result carries the target that was addressed (app,
pid, window title, focused AX element), who actually held keyboard focus, a
`note` explaining the outcome in prose, and machine-readable `warnings`:

`dispatch-failed`, `dispatch-incomplete`, `dispatch-unconfirmed`,
`dispatch-partially-confirmed`, `key-up-not-posted`, `accessibility-not-trusted`,
`target-not-frontmost`, `no-focused-element`.

`key-up-not-posted` is the one warning that describes a lingering side effect
rather than missing evidence: the key-down reached the system but its key-up
could not be created, so a key or modifier may still be held down.

### Limitations

- **Dispatch is not delivery.** macOS offers no API that reports whether an app
  consumed a synthetic key event. `dispatched` means the event entered the
  session event stream — an app that ignores the key produces exactly the same
  reading as one that acts on it.
- **The session key-down counter is shared.** `CGEventSourceCounterForEventType`
  also counts a human at the keyboard and other processes, so the delta is read
  as confirmation (`>=` the number of events posted) and never as a refutation.
  A delta of zero means "unconfirmed", not "definitely not sent".
- **`no-focused-element` is not a failure.** Plenty of apps handle keys at window
  level, and apps with poor AX support (Unity, some Electron IDEs — see
  `CLAUDE.md`) expose no focused element at all while still receiving input fine.
- **Nothing here blocks a keystroke, with one exception.** Warnings annotate the
  result; they never stop a dispatch. The exception is an `appHandle` that no
  longer resolves — expired, or from a previous daemon process. There is nothing
  to activate in that case, so the events would land in whichever app the user is
  currently in; `press_key` rejects with `appNotFound` instead. Reconnect with
  `connect_app` and retry.
- **Cost.** Reporting adds one AX snapshot per call plus a ~20 ms settle before
  the counter is read back — negligible next to the activation poll that already
  precedes every keyboard dispatch, and the settle happens once per call, not per
  keystroke in a `press_keys` sequence.
- **`attempted` is not an instruction to resend.** Duplicate keystrokes are worse
  than an unconfirmed one. Confirm real effects with `query_tree`, `wait_for`, or
  `screenshot` — that composition, not the dispatch report, is how you assert
  that a keystroke did something.

Effect verification (tier `verified`) would need before/after AX snapshots or
`AXObserver` notifications around the press; it is not implemented.

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
