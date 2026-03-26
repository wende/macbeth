// @name dump-ui
// @description Print System Settings accessibility tree
// @usage node skills/SystemSettings/scripts/dump-ui.mjs [--depth 6]

import { connect } from "macbeth";

const args = process.argv.slice(2);
const depth = parseInt(getArg(args, "depth") ?? "6", 10);

const app = await connect("System Settings");
const tree = await app.queryTree({ maxDepth: Number.isFinite(depth) ? depth : 6 });
console.log(tree);

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
