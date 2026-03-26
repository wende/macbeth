---
name: mail
description: Automate Apple Mail using AX for UI interactions and AppleScript for draft/message data flows
---

# Mail Automation

## Connect

`connect_app({ name: "Mail" })`

## Backends

- Primary for UI gaps: AX automation via macbeth
- Supplemental: AppleScript for draft creation and selected-message metadata

## Runnable Scripts

- `dump-ui.mjs` — inspect current Mail AX tree
- `click-toolbar-button.mjs` — click toolbar buttons by title/pattern
- `compose-draft-applescript.mjs` — create and open a draft message
- `selected-message-applescript.mjs` — read currently selected message metadata

## Gotchas

1. AX actions require Mail to be frontmost for reliable interaction.
2. AppleScript coverage is limited for newer Mail UX features.
3. Sending mail is intentionally not done automatically in this v1 set.
