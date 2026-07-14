# Keyboard input and foregrounding

Macbeth can inspect application accessibility trees and set many control values
while an app remains in the background. Its `fill` operation uses those
Accessibility APIs directly, so it does not need to take focus.

`press_key` and `press_keys` are different: they send ordinary macOS keyboard
events. macOS routes those events to the active application, rather than to an
arbitrary background window. Macbeth therefore activates the target app before
delivering keyboard input. This ensures keystrokes reach the intended window
instead of the application the user is currently using.

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
