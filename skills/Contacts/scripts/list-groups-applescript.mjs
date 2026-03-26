// @name list-groups-applescript
// @description List contact groups via AppleScript
// @usage node skills/Contacts/scripts/list-groups-applescript.mjs

import { runAppleScript } from "../../_shared/lib/applescript.mjs";

const output = runAppleScript([
  "tell application \"Contacts\"",
  "set groupNames to name of every group",
  "set AppleScript's text item delimiters to linefeed",
  "return groupNames as text",
  "end tell",
]);

const groups = output
  .split("\n")
  .map((line) => line.trim())
  .filter(Boolean);

console.log(JSON.stringify({ ok: true, groups }, null, 2));
