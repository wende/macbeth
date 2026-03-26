// @name create-note
// @description Create a new note in Apple Notes
// @usage node skills/Notes/scripts/create-note.mjs --title "Ideas" --body "Text" [--folder "Work"]

import { runAppleScript } from "../../_shared/lib/applescript.mjs";

const args = process.argv.slice(2);
const title = getArg(args, "title");
const body = getArg(args, "body");
const folder = getArg(args, "folder") ?? "";

if (!title || !body) {
  console.error("Missing required --title and/or --body");
  process.exit(1);
}

const noteId = runAppleScript([
  "on run argv",
  "set noteTitle to item 1 of argv",
  "set noteBody to item 2 of argv",
  "set folderName to item 3 of argv",
  "tell application \"Notes\"",
  "set createdNote to missing value",
  "if folderName is \"\" then",
  "set createdNote to make new note with properties {name:noteTitle, body:noteBody}",
  "else",
  "repeat with acc in accounts",
  "try",
  "set targetFolder to folder folderName of acc",
  "set createdNote to make new note at targetFolder with properties {name:noteTitle, body:noteBody}",
  "exit repeat",
  "end try",
  "end repeat",
  "if createdNote is missing value then",
  "set createdNote to make new note with properties {name:noteTitle, body:noteBody}",
  "end if",
  "end if",
  "return id of createdNote as text",
  "end tell",
  "end run",
], [title, body, folder]);

console.log(JSON.stringify({ ok: true, item: { id: noteId.trim(), title } }, null, 2));

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
