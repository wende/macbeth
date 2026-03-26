// @name list-events
// @description List upcoming calendar events via EventKit bridge
// @usage node skills/Calendar/scripts/list-events.mjs [--calendar "Work"] [--days 7]

import { runNativeBridge } from "../../_shared/lib/native-bridge.mjs";

const args = process.argv.slice(2);
const calendar = getArg(args, "calendar");
const days = getArg(args, "days") ?? "7";

const bridgeArgs = ["calendar-list", "--days", days];
if (calendar) bridgeArgs.push("--calendar", calendar);

const out = runNativeBridge(bridgeArgs);
console.log(JSON.stringify(out, null, 2));
if (out?.ok === false) process.exit(1);

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
