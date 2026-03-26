---
name: calendar
description: Minimal Calendar automation using EventKit with optional Shortcuts integration
---

# Calendar Automation

## Connect

`connect_app({ name: "Calendar" })`

## Backends

- Primary: EventKit bridge (`skills/_shared/native/apple_data.swift`)
- Integration: Shortcuts for custom calendar workflows

## Runnable Scripts

- `list-events.mjs` — list upcoming events
- `create-event.mjs` — create an event with title/start/end
## Gotchas

1. First run prompts for Calendar access.
2. Times should be ISO 8601.
3. This v1 skill intentionally avoids delete/remove operations.
