---
name: systemsettings
description: AX-first automation for System Settings panes, search, and controls
---

# System Settings Automation

## Connect

`connect_app({ name: "System Settings" })`

## Backends

- Primary: Accessibility automation only (no stable public API)
- Optional helper: URL scheme (`x-apple.systempreferences:`) to jump to panes

## Runnable Scripts

- `open-pane.mjs` — open a settings pane by identifier
- `search-setting.mjs` — type into the Settings search field
- `click-control.mjs` — click controls by role/title or pattern
- `dump-ui.mjs` — inspect current AX tree for locator discovery

## Gotchas

1. AX labels differ by macOS version and system language.
2. Pane identifiers are not validated by the script; invalid IDs open the app root.
3. For safety, scripts avoid multi-step destructive interactions.
