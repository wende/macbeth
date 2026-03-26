---
name: reminders
description: List, create, and complete reminders using EventKit with AppleScript/Shortcuts fallbacks
---

# Reminders Automation

## Connect

`connect_app({ name: "Reminders" })`

## Backends

- Primary: EventKit bridge (`skills/_shared/native/apple_data.swift`)
- Fallback: AppleScript for simple app-level interactions
- Integration: Shortcuts for custom workflows

## Runnable Scripts

- `list-reminders.mjs` — list reminders (optional list filter)
- `create-reminder.mjs` — create a reminder with optional due date
- `complete-reminder.mjs` — mark reminder completed by id
## Gotchas

1. First run will prompt for Reminders permissions.
2. Due dates should be ISO 8601 (for example `2026-03-26T17:00:00+01:00`).
3. Completion is by reminder id; use `list-reminders` first.
