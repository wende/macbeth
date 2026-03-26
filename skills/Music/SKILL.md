---
name: music
description: Automate Apple Music with AppleScript plus AX support for UI-only controls
---

# Music Automation

## Connect

`connect_app({ name: "Music" })`

## Backends

- Primary: AppleScript for playback and library commands
- Supplemental: AX automation for UI controls without direct script support

## Runnable Scripts

- `now-playing.mjs` — read current track metadata
- `search-and-play.mjs` — search library and play first match
- `click-control-ax.mjs` — click a UI button by title/pattern
## Gotchas

1. Search-and-play uses the first matching track result.
2. AX button labels differ across macOS versions/locales.
3. Destructive library operations are intentionally omitted.
