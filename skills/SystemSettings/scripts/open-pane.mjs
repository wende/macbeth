// @name open-pane
// @description Open a System Settings pane by identifier
// @usage node skills/SystemSettings/scripts/open-pane.mjs --id "com.apple.Network-Settings.extension"

import { run } from "../../_shared/lib/shell.mjs";

const args = process.argv.slice(2);
const paneId = getArg(args, "id");
if (!paneId) {
  console.error("Missing required --id");
  process.exit(1);
}

run("open", [`x-apple.systempreferences:${paneId}`]);
console.log(JSON.stringify({ ok: true, paneId }, null, 2));

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
