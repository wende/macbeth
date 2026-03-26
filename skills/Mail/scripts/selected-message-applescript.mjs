// @name selected-message-applescript
// @description Read metadata for the currently selected Mail message via AppleScript
// @usage node skills/Mail/scripts/selected-message-applescript.mjs

import { runAppleScript } from "../../_shared/lib/applescript.mjs";

const output = runAppleScript([
  "tell application \"Mail\"",
  "set selectedMessages to selection",
  "if (count of selectedMessages) is 0 then return \"\"",
  "set m to item 1 of selectedMessages",
  "return (subject of m as text) & \"|||\" & (sender of m as text) & \"|||\" & ((date received of m) as text)",
  "end tell",
]);

if (!output) {
  console.log(JSON.stringify({ ok: true, item: null }, null, 2));
  process.exit(0);
}

const [subject, sender, receivedAt] = output.split("|||");
console.log(JSON.stringify({ ok: true, item: { subject, sender, receivedAt } }, null, 2));
