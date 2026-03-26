// @name search-place
// @description Search for a place in Maps via AX
// @usage node skills/Maps/scripts/search-place.mjs --query "coffee near me"

import { connect } from "macbeth";

const args = process.argv.slice(2);
const query = getArg(args, "query");
if (!query) {
  console.error("Missing required --query");
  process.exit(1);
}

const app = await connect("Maps");
const searchField = app.locator({ role: "window" }).locator({ role: "text_field" });
await searchField.fill(query, { timeout: 10_000 });
await app.pressKey("return");
console.log(JSON.stringify({ ok: true, query }, null, 2));

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
