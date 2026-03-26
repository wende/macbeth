---
name: notes
description: List and write Apple Notes using AppleScript with optional Shortcuts integration
---

# Notes Automation

## Connect

`connect_app({ name: "Notes" })`

## Backends

- Primary: AppleScript (`osascript`)
- Integration: Shortcuts for custom automations

## Runnable Scripts

- `list-notes.mjs` — list notes (optionally by folder)
- `create-note.mjs` — create a note with title/body
- `append-note.mjs` — append text to an existing note by exact title
## Gotchas

1. Notes body is rich text (HTML under the hood), so plain text appends are inserted with `<br>`.
2. Folder matching uses the folder name across all accounts and takes the first match.
3. First automation run may prompt for Notes/Automation permission.
