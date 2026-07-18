# Interaction indicator

When an MCP tool or daemon method addresses an app window, Macbeth shows a violet outline and edge glow on that window. Click/fill add a synthetic pointer; screenshots add a scan/snap so demos show which app is controlled without lighting the whole display.

## How it works

- The daemon has no AppKit run loop. Overlays are rendered by `macbeth-glow`, spawned lazily and driven over stdin as newline-delimited JSON (`activate`, `deactivate`, window-focus, capture, shutdown).
- Activity is reference-counted across overlapping work. MCP uses tokenized `begin_activity` / `end_activity` so nested actions do not turn off each other’s glow.
- Window-local glow appears only when the targeted window is system frontmost at the start of the operation. Background inspect/manipulate skips outline, pointer, and capture animation. If the app loses frontmost, outlines drop immediately. Paths that must activate (`press_key` / `press_keys`, keyboard `fill`, Electron auto-fill) re-present the outline after activation.
- Outlines are per stable process/window identity; several windows of the frontmost app can stay outlined. Only the frontmost app has chrome. After the last overlapping operation, each outline holds 400ms then fades 100ms. Re-addressing refreshes the deadline without restarting fade-in.
- Click/fill move a synthetic pointer to the resolved AX element (never the real cursor). Keyboard-only ops leave it at the last honest target. First approach from a synthetic offset; later targets ease from the previous position.
- Screenshots and app-window OCR intensify the perimeter with a scan and snap. Overlays use `sharingType = .readOnly` so single-window Macbeth captures stay clean while external recordings still show the animation.
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
