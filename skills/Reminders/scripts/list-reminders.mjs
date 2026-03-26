// @name list-reminders
// @description List reminders via EventKit bridge
// @usage node skills/Reminders/scripts/list-reminders.mjs [--list "Work"] [--include-completed]

import { runNativeBridge } from "../../_shared/lib/native-bridge.mjs";

const args = process.argv.slice(2);
const list = getArg(args, "list");
const includeCompleted = args.includes("--include-completed");

const bridgeArgs = ["reminders-list"];
if (list) bridgeArgs.push("--list", list);
if (includeCompleted) bridgeArgs.push("--include-completed");

const out = runNativeBridge(bridgeArgs);
console.log(JSON.stringify(out, null, 2));
if (out?.ok === false) process.exit(1);

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
