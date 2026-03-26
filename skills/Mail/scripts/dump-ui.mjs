// @name dump-ui
// @description Print Mail accessibility tree for locator discovery
// @usage node skills/Mail/scripts/dump-ui.mjs [--depth 5]

import { connect } from "macbeth";

const args = process.argv.slice(2);
const depth = parseInt(getArg(args, "depth") ?? "5", 10);

const app = await connect("Mail");
const tree = await app.queryTree({ maxDepth: Number.isFinite(depth) ? depth : 5 });
console.log(tree);

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
