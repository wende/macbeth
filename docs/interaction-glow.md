# Interaction indicator

When an MCP tool or daemon method addresses an app window, Macbeth shows a violet outline and edge glow on that window. Click/fill add a synthetic pointer; screenshots add a scan/snap so demos show which app is controlled without lighting the whole display.

## How it works

- The daemon has no AppKit run loop. Overlays are rendered by `macbeth-glow`, spawned lazily and driven over stdin as newline-delimited JSON (`activate`, `deactivate`, window-focus, capture, shutdown).
- Activity is reference-counted across overlapping work. MCP uses tokenized `begin_activity` / `end_activity` so nested actions do not turn off each other’s glow.
- Window outline and synthetic pointer appear only when the targeted window is system frontmost at the start of the operation. Background inspect/manipulate skips those. If the app loses frontmost, outlines drop immediately. Paths that must activate (`press_key` / `press_keys`, keyboard `fill`, Electron auto-fill) re-present the outline after activation. Screenshot capture scan/snap still runs while backgrounded so demos and external recordings can show which window is being captured (e.g. when a screen recorder holds frontmost).
- Outlines are per stable process/window identity; several windows of the frontmost app can stay outlined. Only the frontmost app has chrome. After the last overlapping operation, each outline holds 400ms then fades 100ms. Re-addressing refreshes the deadline without restarting fade-in.
- Click/fill move a synthetic pointer to the resolved AX element (never the real cursor). Keyboard-only ops leave it at the last honest target. First approach from a synthetic offset; later targets ease from the previous position.
- Screenshots intensify the perimeter with a scan and snap (OCR keeps only the optional frontmost activity ring to avoid the ~1s presentation delay). Overlays use `sharingType = .readOnly` so single-window Macbeth captures stay clean while external recordings still show the animation.
- Best-effort: if the helper fails, the daemon logs a warning and continues — automation is never blocked.

## Configuration

Environment variables (daemon) and `--no-glow`:

| Variable | Default | Description |
|---|---|---|
| `MACBETH_GLOW` | `1` | `0` / `false` / `off` / `no` disables the indicator (same as `--no-glow`). |
| `MACBETH_GLOW_COLOR` | `#8B3342` | Accent hex (`#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`). |
| `MACBETH_GLOW_DEBOUNCE_MS` | `400` | Hold (ms) after final activity before the 100ms fade. |
| `MACBETH_GLOW_HELPER` | — | Explicit path to `macbeth-glow` (else next to `macbethd`). |

All presentation layers are click-through and owned by the helper process.

## README presentation demo

For a short (~20–30s) screen recording that only shows external chrome (outline, pointer, form changes, capture scan/snap):

```bash
npm run demo:presentation
# continuous fast presentation (no pacing pauses):
npm run demo:presentation -- --fast

# Run the same fixture/tool feature set while keeping your current app in front.
# The summary reports every focus interruption and its observed duration:
npm run demo:background
# continuous version:
npm run demo:background -- --fast
```

Uses the native and Electron test fixtures side-by-side. Hide the terminal before the countdown; stop capture after “Recording complete”. Full feature integration lives in `npm run demo:mcp`.
The demo invokes ordinary Macbeth tools only; their automatic activity scopes
buffer and hand off the glow without demo-specific glow-control calls.

`demo:background` keeps the app that launched the command frontmost, explicitly
re-backgrounds each fixture before every action, and runs the presentation
feature set: connect, native and Electron fill/click, and screenshot. A
read-only `NSWorkspace` observer records even brief focus steals that are
restored before a tool returns. Interruptions are observations, not demo
failures; tool errors still fail the command.
