// @name create-event
// @description Create a calendar event via EventKit bridge
// @usage node skills/Calendar/scripts/create-event.mjs --title "Standup" --start "2026-03-27T09:00:00+01:00" --end "2026-03-27T09:15:00+01:00" [--calendar "Work"]

import { runNativeBridge } from "../../_shared/lib/native-bridge.mjs";

const args = process.argv.slice(2);
const title = getArg(args, "title");
const start = getArg(args, "start");
const end = getArg(args, "end");
if (!title || !start || !end) {
  console.error("Missing required --title, --start, and/or --end");
  process.exit(1);
}

const bridgeArgs = [
  "calendar-add",
  "--title", title,
  "--start", start,
  "--end", end,
];

const calendar = getArg(args, "calendar");
const notes = getArg(args, "notes");
const location = getArg(args, "location");
if (calendar) bridgeArgs.push("--calendar", calendar);
if (notes) bridgeArgs.push("--notes", notes);
if (location) bridgeArgs.push("--location", location);

const out = runNativeBridge(bridgeArgs);
console.log(JSON.stringify(out, null, 2));
if (out?.ok === false) process.exit(1);

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
