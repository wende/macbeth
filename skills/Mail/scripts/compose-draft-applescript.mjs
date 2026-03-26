// @name compose-draft-applescript
// @description Create a Mail draft via AppleScript (does not auto-send)
// @usage node skills/Mail/scripts/compose-draft-applescript.mjs [--to "user@example.com"] [--subject "Hello"] [--body "Hi there"]

import { runAppleScript } from "../../_shared/lib/applescript.mjs";

const args = process.argv.slice(2);
const to = getArg(args, "to") ?? "";
const subject = getArg(args, "subject") ?? "";
const body = getArg(args, "body") ?? "";

runAppleScript([
  "on run argv",
  "set recipientEmail to item 1 of argv",
  "set msgSubject to item 2 of argv",
  "set msgBody to item 3 of argv",
  "tell application \"Mail\"",
  "set newMessage to make new outgoing message with properties {subject:msgSubject, content:(msgBody & return), visible:true}",
  "tell newMessage",
  "if recipientEmail is not \"\" then",
  "make new to recipient at end of to recipients with properties {address:recipientEmail}",
  "end if",
  "end tell",
  "activate",
  "end tell",
  "end run",
], [to, subject, body]);

console.log(JSON.stringify({ ok: true, draft: { to, subject } }, null, 2));

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
