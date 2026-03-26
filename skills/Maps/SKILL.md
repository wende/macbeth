---
name: maps
description: AX-first automation for Apple Maps search and result interactions
---

# Maps Automation

## Connect

`connect_app({ name: "Maps" })`

## Backends

- Primary: Accessibility automation (search field, results, controls)
- Helper: `maps://` URL scheme for predictable directions launch

## Runnable Scripts

- `search-place.mjs` — search for a place using AX
- `click-result-row.mjs` — click a result row by index
- `open-directions.mjs` — open directions via URL scheme
- `dump-ui.mjs` — inspect current AX tree

## Gotchas

1. AX result tree shape changes by app state and map mode.
2. Ensure Maps is frontmost before AX actions.
3. URL-based directions are used for reliability when AX result controls are dynamic.
