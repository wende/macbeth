// @name click-control-ax
// @description Click a Music UI control button using AX
// @usage node skills/Music/scripts/click-control-ax.mjs [--title "Play"] [--pattern "Play|Pause"]

import { connect } from "macbeth";

const args = process.argv.slice(2);
const title = getArg(args, "title");
const pattern = getArg(args, "pattern");

if (!title && !pattern) {
  console.error("Provide --title or --pattern");
  process.exit(1);
}

const app = await connect("Music");
let target;
if (title) {
  target = app.locator({ role: "window" }).locator({ role: "button", title });
} else {
  target = app.locator({ role: "window" }).locator({ role: "button", titlePattern: pattern });
}

await target.click({ timeout: 10_000 });
console.log("Clicked control.");

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
