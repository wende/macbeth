// @name list-notes
// @description List notes from Apple Notes (optional folder filter)
// @usage node skills/Notes/scripts/list-notes.mjs [--folder "Work"] [--limit 20]

import { runAppleScript } from "../../_shared/lib/applescript.mjs";

const args = process.argv.slice(2);
const folder = getArg(args, "folder") ?? "";
const limit = parseInt(getArg(args, "limit") ?? "20", 10);

const output = runAppleScript([
  "on run argv",
  "set folderName to item 1 of argv",
  "set maxItems to (item 2 of argv) as integer",
  "tell application \"Notes\"",
  "set rows to {}",
  "set selectedNotes to {}",
  "if folderName is \"\" then",
  "set selectedNotes to notes",
  "else",
  "repeat with acc in accounts",
  "try",
  "set selectedNotes to notes of folder folderName of acc",
  "exit repeat",
  "end try",
  "end repeat",
  "end if",
  "set nCount to count of selectedNotes",
  "if nCount > maxItems then set nCount to maxItems",
  "repeat with i from 1 to nCount",
  "set n to item i of selectedNotes",
  "set end of rows to ((id of n as text) & \"|||\" & (name of n as text) & \"|||\" & ((modification date of n) as text))",
  "end repeat",
  "set AppleScript's text item delimiters to linefeed",
  "return rows as text",
  "end tell",
  "end run",
], [folder, String(limit)]);

const items = (output ? output.split("\n") : [])
  .map((line) => line.trim())
  .filter(Boolean)
  .map((line) => {
    const [id, title, modifiedAt] = line.split("|||");
    return { id, title, modifiedAt };
  });

console.log(JSON.stringify({ ok: true, items }, null, 2));

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
