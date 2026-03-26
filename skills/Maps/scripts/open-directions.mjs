// @name open-directions
// @description Open Maps directions using maps:// URL scheme
// @usage node skills/Maps/scripts/open-directions.mjs --to "Warsaw Central Station" [--from "Current Location"]

import { run } from "../../_shared/lib/shell.mjs";

const args = process.argv.slice(2);
const to = getArg(args, "to");
if (!to) {
  console.error("Missing required --to");
  process.exit(1);
}

const from = getArg(args, "from");
const url = new URL("maps://");
url.searchParams.set("daddr", to);
if (from) url.searchParams.set("saddr", from);

run("open", [url.toString()]);
console.log(JSON.stringify({ ok: true, to, from: from ?? null }, null, 2));

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
