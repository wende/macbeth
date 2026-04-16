---
name: logicpro
description: AX-first automation for Logic Pro — transport, tracks, tempo, mixer, and view controls
---

# Logic Pro Automation

## Connect

`connect_app({ name: "Logic Pro" })`

## Backends

- Primary: Accessibility automation (menu bar, transport, tracks, mixer, view toggles)
- Prefer menu bar actions over keyboard shortcuts — shortcuts steal focus and can misfire

## Layout

Logic Pro's main window has these regions (top to bottom, left to right):

1. **Control Bar** (top) — transport buttons, LCD display (tempo/time sig/key), view toggles
2. **Inspector** (left panel) — Region and Track properties, channel strip
3. **Tracks Area** (center) — timeline with track headers and regions
4. **Editors/Mixer** (bottom, toggled) — Piano Roll, Audio Editor, Mixer, etc.

## Key Elements

### Menu Bar (preferred for actions)

Use `select_menu_item` instead of keyboard shortcuts — it's a single atomic call via System Events, no focus stealing.

```
select_menu_item({ app: "Logic Pro", menuPath: ["Track", "New Audio Track"] })
```

| Menu | Item | Notes |
|------|------|-------|
| Track | New Audio Track | Opens track creation dialog |
| Track | New Software Instrument Track | Opens track creation dialog |
| Track | New Session Player SI Track... | Opens track creation dialog |
| Track | Delete Track | |
| Track | Rename Track | |
| File | Bounce Project... | Cmd+B equivalent |
| File | Save | Cmd+S equivalent |
| Edit | Undo | Cmd+Z equivalent |

### Transport Controls

| Element | Role | Query |
|---------|------|-------|
| Play | checkbox | `[{role:'checkbox', title:'Play'}]` |
| Stop | button | `[{role:'button', title:'Stop'}]` |
| Record | checkbox | `[{role:'checkbox', title:'Record'}]` |
| Cycle | checkbox | `[{role:'checkbox', title:'Cycle'}]` |
| Count In | checkbox | `[{role:'checkbox', title:'Count In'}]` |
| Metronome | checkbox | `[{role:'checkbox', title:'Metronome Click'}]` |
| Solo | checkbox | `[{role:'checkbox', title:'Solo'}]` |
| Replace | checkbox | `[{role:'checkbox', title:'Replace'}]` |
| Tuner | checkbox | `[{role:'checkbox', title:'Tuner'}]` |

### LCD Display

| Element | Role | Query |
|---------|------|-------|
| Tempo | slider | `[{role:'slider', index:2}]` inside the LCD group |
| Time Signature | popup | `[{role:'popup', title:'4/4'}]` (value changes) |
| Key | popup | `[{role:'popup', titlePattern:'Major\|Minor\|Dorian'}]` |
| Display Mode | popup | `[{role:'popup', title:'Beats & Project'}]` |

### View Toggles (Control Bar, right side)

All are checkboxes with value "0" (hidden) or "1" (shown):

| Toggle | Query |
|--------|-------|
| Library | `[{role:'checkbox', title:'Library'}]` |
| Inspector | `[{role:'checkbox', title:'Inspector'}]` |
| Smart Controls | `[{role:'checkbox', title:'Smart Controls'}]` |
| Mixer | `[{role:'checkbox', title:'Mixer'}]` |
| Editors | `[{role:'checkbox', title:'Editors'}]` |
| List Editors | `[{role:'checkbox', title:'List Editors'}]` |
| Loop Browser | `[{role:'checkbox', title:'Loop Browser'}]` |
| Browsers | `[{role:'checkbox', title:'Browsers'}]` |

## Gotchas

1. Transport buttons (Play, Record, Cycle, etc.) are **checkboxes**, not buttons — they toggle on/off. Stop is the only button.
2. The tempo is a **slider** (label: "Tempo", min: 5, max: 990). Use `fill` to set it — under the hood this uses AXIncrement/AXDecrement in steps of ~10, so the final value may overshoot slightly.
3. AXSetValue on Logic Pro sliders does NOT set the absolute value — it just increments by 1. Always use `fill` which handles this correctly via AXIncrement/AXDecrement.
4. Many channel strip controls in the Inspector are **disabled** by default — they become enabled when the track is selected and the inspector section is expanded.
5. "New Track" menu items open a dialog — after clicking the menu item, you may need to interact with the dialog to finalize track creation.
6. The Screensets menu uses numbers (1-9) as menu bar items — don't confuse with regular menus.

## Workflows

### Add a new audio track
```
select_menu_item({ app: "Logic Pro", menuPath: ["Track", "New Audio Track"] })
```

### Play/Stop a project
```
app.checkbox("Play").click()
# or app.button("Stop").click()
```

### Set tempo to 140 BPM
```
app.locator({ role: 'slider', index: 0 }).fill("140")
```

### Bounce project
```
select_menu_item({ app: "Logic Pro", menuPath: ["File", "Bounce Project..."] })
```

### Toggle mixer view
```
app.checkbox("Mixer").click()
```

## Runnable Scripts

- `transport.mjs` — control transport (play, stop, record, toggle metronome/cycle)
- `set-tempo.mjs` — set project tempo
- `add-track.mjs` — add a new track via menu
