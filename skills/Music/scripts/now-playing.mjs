// @name now-playing
// @description Get current track metadata from Music.app
// @usage node skills/Music/scripts/now-playing.mjs

import { runAppleScript } from "../../_shared/lib/applescript.mjs";

const output = runAppleScript([
  "tell application \"Music\"",
  "if player state is stopped then return \"\"",
  "set t to current track",
  "return (name of t as text) & \"|||\" & (artist of t as text) & \"|||\" & (album of t as text) & \"|||\" & (player state as text)",
  "end tell",
]);

if (!output) {
  console.log(JSON.stringify({ ok: true, item: null }, null, 2));
  process.exit(0);
}

const [name, artist, album, state] = output.split("|||");
console.log(JSON.stringify({ ok: true, item: { name, artist, album, state } }, null, 2));
