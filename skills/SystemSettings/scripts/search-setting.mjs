// @name search-setting
// @description Search in System Settings using AX text field fill
// @usage node skills/SystemSettings/scripts/search-setting.mjs --query "firewall"

import { execSync } from "node:child_process";
import { connect } from "macbeth";

const args = process.argv.slice(2);
const query = getArg(args, "query");
if (!query) {
  console.error("Missing required --query");
  process.exit(1);
}

try {
  execSync('open -a "System Settings"', { stdio: "ignore" });
  await sleep(1000);

  const app = await connect("System Settings");
  const searchField = app
    .locator({ role: "window" })
    .locator({ role: "text_field" });
  await searchField.fill(query, { timeout: 15_000 });
  console.log(JSON.stringify({ ok: true, query }, null, 2));
} catch (err) {
  console.log(JSON.stringify({ ok: false, error: err.message }, null, 2));
  process.exit(1);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
