# MCP Skill Bugs

## Current test-harness findings

| Area | Finding | Status |
|---|---|---|
| Legacy Swift harness | The former `swift run` test package was not an application bundle, so macOS did not register it in `NSWorkspace`, the Dock, or Macbeth's `list_apps`. | **Fixed** — replaced by the packaged AppKit test harness. |
| Screenshot | A ScreenCaptureKit screenshot request could time out rather than returning a bounded permission or capture error. | **Fixed** — capture is bounded and covered by the MCP-only demo. |
| OCR | `extract_text` with supplied image data could double-resume a continuation and close the daemon connection; app-window OCR could exceed the client timeout. | **Fixed** — OCR now performs synchronously without unsafe continuation bridging and uses a bounded 1x fast-recognition path. |
| Menu inspection | System Events menu inspection can fail for the former unbundled Swift executable. | **Resolved by replacement** — the packaged harness is a regular app. |

| No. | App | Bug | Severity | script file | Status |
|---:|---|---|---|---|---|
| 1 | Reminders | `create-reminder` fails with `EKErrorDomain error 29`; create flow is not reliable in current setup. | High | `skills/Reminders/scripts/create-reminder.mjs` | **Fixed** — uses EventKit bridge directly; writable list resolution via `resolveReminderCalendar` |
| 2 | Reminders | `complete-reminder` requires ID but fails immediately when ID is missing/invalid; no recovery path from list/create workflow. | Medium | `skills/Reminders/scripts/complete-reminder.mjs` | **Fixed** — now resolves by `--title` with fuzzy matching; lists candidates on failure |
| 3 | Reminders | `run-shortcut` fails (`Couldn't find shortcut` / `Empty Shortcut` / open-app failure). | High | ~~`skills/Reminders/scripts/run-shortcut.mjs`~~ | **Fixed** — per-skill scripts replaced by `run_shortcut` / `list_shortcuts` MCP tools with fuzzy matching and validation |
| 4 | Notes | `run-shortcut` fails with the same shortcut runtime errors. | High | ~~`skills/Notes/scripts/run-shortcut.mjs`~~ | **Fixed** — same as #3 |
| 5 | Contacts | `search-contacts` hard-fails on permissions (`Contacts permission denied`) without fallback handling. | Medium | `skills/Contacts/scripts/search-contacts.mjs` | **Fixed** — catches permission error, returns structured JSON with actionable hint |
| 6 | Contacts | `add-contact` hard-fails on permissions (`Contacts permission denied`) without fallback handling. | Medium | `skills/Contacts/scripts/add-contact.mjs` | **Fixed** — same as #5; Swift bridge error message now includes System Settings path |
| 7 | Contacts | `run-shortcut` fails with shortcut runtime errors. | High | ~~`skills/Contacts/scripts/run-shortcut.mjs`~~ | **Fixed** — same as #3 |
| 8 | Calendar | `create-event` rejects common JS ISO datetime with milliseconds; with strict format it still fails if no writable calendar is available. | High | `skills/Calendar/scripts/create-event.mjs` | **Fixed** — `parseISODate` now handles fractional seconds; `calendarAdd` checks `allowsContentModifications` with fallback to any writable calendar |
| 9 | Calendar | `run-shortcut` fails with shortcut runtime errors. | High | ~~`skills/Calendar/scripts/run-shortcut.mjs`~~ | **Fixed** — same as #3 |
| 10 | Mail | `click-toolbar-button` is brittle for realistic patterns/titles and can fail with `Element not found within 10.0s`. | Medium | `skills/Mail/scripts/click-toolbar-button.mjs` | **Fixed** — removed rigid `toolbar` intermediate locator; searches window descendants directly; structured error handling |
| 11 | Music | `click-control-ax` often fails with `Element not found`; selector strategy is too fragile. | Medium | `skills/Music/scripts/click-control-ax.mjs` | **Fixed** — same pattern as #10; broader window-level search with structured error handling |
| 12 | Music | `run-shortcut` fails with shortcut runtime errors. | High | ~~`skills/Music/scripts/run-shortcut.mjs`~~ | **Fixed** — same as #3 |
| 13 | SystemSettings | `search-setting` intermittently fails with socket connection errors (`ECONNREFUSED /tmp/macbeth-501.sock`) and/or missing element targeting. | High | `skills/SystemSettings/scripts/search-setting.mjs` | **Fixed** — launches app via `open -a` before connecting; structured error handling |
| 14 | SystemSettings | `click-control` fails in real runs (`No running app` / `Element not found`), indicating unstable app-state and locator handling. | High | `skills/SystemSettings/scripts/click-control.mjs` | **Fixed** — same as #13 |
| 15 | Maps | `click-result-row` fails with `Element not found`; row indexing assumes UI state that is often not present yet. | Medium | `skills/Maps/scripts/click-result-row.mjs` | **Fixed** — waits for first row to appear before clicking target index; structured error handling |
