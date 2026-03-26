// @name create-reminder
// @description Create a reminder via EventKit bridge
// @usage node skills/Reminders/scripts/create-reminder.mjs --title "Pay rent" [--list "Personal"] [--due "2026-03-31T09:00:00+01:00"]

import { runNativeBridge } from "../../_shared/lib/native-bridge.mjs";

const args = process.argv.slice(2);
const title = getArg(args, "title");
if (!title) {
  console.error("Missing required --title");
  process.exit(1);
}

const bridgeArgs = ["reminders-add", "--title", title];
const list = getArg(args, "list");
const due = getArg(args, "due");
const notes = getArg(args, "notes");
const priority = getArg(args, "priority");

if (list) bridgeArgs.push("--list", list);
if (due) bridgeArgs.push("--due", due);
if (notes) bridgeArgs.push("--notes", notes);
if (priority) bridgeArgs.push("--priority", priority);

const out = runNativeBridge(bridgeArgs);
console.log(JSON.stringify(out, null, 2));
if (out?.ok === false) process.exit(1);

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
