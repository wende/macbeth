// @name get-tabs
// @description Lists all open Safari tabs with their titles and active state
// @usage node scripts/get-tabs.mjs

import { connect } from "macbeth";

const app = await connect("Safari");
const tree = await app.queryTree({ maxDepth: 4 });

const tabLines = tree
  .split("\n")
  .filter((line) => line.includes('[radio "'))
  .map((line) => {
    const titleMatch = line.match(/\[radio "(.+?)"/);
    const active = line.includes('value:"1"');
    return `${active ? "* " : "  "}${titleMatch?.[1] ?? "Untitled"}`;
  });

console.log(`${tabLines.length} tab(s):`);
tabLines.forEach((t) => console.log(t));
