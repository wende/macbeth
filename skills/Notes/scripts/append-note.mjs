// @name append-note
// @description Append text to a note selected by exact title
// @usage node skills/Notes/scripts/append-note.mjs --title "Ideas" --text "Another item"

import { runAppleScript } from "../../_shared/lib/applescript.mjs";

const args = process.argv.slice(2);
const title = getArg(args, "title");
const text = getArg(args, "text");

if (!title || !text) {
  console.error("Missing required --title and/or --text");
  process.exit(1);
}

const noteId = runAppleScript([
  "on run argv",
  "set targetTitle to item 1 of argv",
  "set appendText to item 2 of argv",
  "tell application \"Notes\"",
  "set targetNote to missing value",
  "repeat with n in notes",
  "if (name of n as text) is targetTitle then",
  "set targetNote to n",
  "exit repeat",
  "end if",
  "end repeat",
  "if targetNote is missing value then error \"Note not found\"",
  "set body of targetNote to ((body of targetNote) & \"<br>\" & appendText)",
  "return id of targetNote as text",
  "end tell",
  "end run",
], [title, text]);

console.log(JSON.stringify({ ok: true, item: { id: noteId.trim(), title } }, null, 2));

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
