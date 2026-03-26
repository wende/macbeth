// @name click-toolbar-button
// @description Click a Mail toolbar button by exact title or regex pattern
// @usage node skills/Mail/scripts/click-toolbar-button.mjs [--title "Reply"] [--pattern "Send|Reply"]

import { connect } from "macbeth";

const args = process.argv.slice(2);
const title = getArg(args, "title");
const pattern = getArg(args, "pattern");

if (!title && !pattern) {
  console.error("Provide --title or --pattern");
  process.exit(1);
}

try {
  const app = await connect("Mail");
  const win = app.locator({ role: "window" });
  const query = { role: "button" };
  if (title) query.title = title;
  else query.titlePattern = pattern;

  await win.locator(query).click({ timeout: 15_000 });
  console.log("Clicked toolbar button.");
} catch (err) {
  console.log(JSON.stringify({ ok: false, error: err.message }, null, 2));
  process.exit(1);
}

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
