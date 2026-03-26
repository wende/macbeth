// @name click-control
// @description Click a System Settings control by role and title/pattern
// @usage node skills/SystemSettings/scripts/click-control.mjs [--role "button"] [--title "Wi-Fi"] [--pattern "Wi-Fi|Bluetooth"]

import { execSync } from "node:child_process";
import { connect } from "macbeth";

const args = process.argv.slice(2);
const role = getArg(args, "role") ?? "button";
const title = getArg(args, "title");
const pattern = getArg(args, "pattern");

if (!title && !pattern) {
  console.error("Provide --title or --pattern");
  process.exit(1);
}

try {
  execSync('open -a "System Settings"', { stdio: "ignore" });
  await sleep(1000);

  const app = await connect("System Settings");
  const query = { role };
  if (title) query.title = title;
  if (pattern) query.titlePattern = pattern;

  await app.locator({ role: "window" }).locator(query).click({ timeout: 15_000 });
  console.log(JSON.stringify({ ok: true, role, title: title ?? null, pattern: pattern ?? null }, null, 2));
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
