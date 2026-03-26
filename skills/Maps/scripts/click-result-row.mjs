// @name click-result-row
// @description Click a Maps result row by index
// @usage node skills/Maps/scripts/click-result-row.mjs [--index 0]

import { connect } from "macbeth";

const args = process.argv.slice(2);
const idx = parseInt(getArg(args, "index") ?? "0", 10);
const rowIndex = Number.isFinite(idx) ? idx : 0;

try {
  const app = await connect("Maps");
  const win = app.locator({ role: "window" });

  // Wait for at least one row to appear before clicking by index
  await win.locator({ role: "row", index: 0 }).waitFor({ timeout: 15_000 });
  await win.locator({ role: "row", index: rowIndex }).click({ timeout: 5_000 });
  console.log(JSON.stringify({ ok: true, index: rowIndex }, null, 2));
} catch (err) {
  console.log(JSON.stringify({ ok: false, error: err.message, index: rowIndex }, null, 2));
  process.exit(1);
}

function getArg(argv, name) {
  const i = argv.indexOf(`--${name}`);
  if (i === -1 || i + 1 >= argv.length) return undefined;
  return argv[i + 1];
}
