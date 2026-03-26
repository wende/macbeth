---
name: contacts
description: Search and create contacts via CNContact, with AppleScript/Shortcuts helpers
---

# Contacts Automation

## Connect

`connect_app({ name: "Contacts" })`

## Backends

- Primary: Contacts framework bridge (`CNContactStore`)
- Fallback: AppleScript for group and app-specific operations
- Integration: Shortcuts for custom pipelines

## Runnable Scripts

- `search-contacts.mjs` — search contacts by name/org text
- `add-contact.mjs` — create a contact (name + optional email/phone)
- `list-groups-applescript.mjs` — list contact groups via AppleScript
## Gotchas

1. First run will prompt for Contacts permission.
2. Search is substring-based over display name and organization.
3. This skill avoids destructive delete actions by default.
