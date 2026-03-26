// @name search-and-play
// @description Search Music library by name and play first match
// @usage node skills/Music/scripts/search-and-play.mjs --query "Daft Punk"

import { runAppleScript } from "../../_shared/lib/applescript.mjs";

const args = process.argv.slice(2);
const query = getArg(args, "query");
if (!query) {
  console.error("Missing required --query");
  process.exit(1);
}

const output = runAppleScript([
  "on run argv",
  "set needle to item 1 of argv",
  "tell application \"Music\"",
  "set tracksFound to (every track of library playlist 1 whose name contains needle)",
  "if (count of tracksFound) is 0 then error \"No track found\"",
  "set t to item 1 of tracksFound",
  "play t",
  "return (name of t as text) & \"|||\" & (artist of t as text)",
  "end tell",
  "end run",
], [query]);

const [name, artist] = output.split("|||");
console.log(JSON.stringify({ ok: true, item: { name, artist } }, null, 2));

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
