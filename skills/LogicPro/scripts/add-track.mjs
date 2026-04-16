// @name add-track
// @description Add a new track to Logic Pro via the Track menu
// @usage node skills/LogicPro/scripts/add-track.mjs --type audio|instrument|session-player

import { runAppleScript } from "macbeth/dist/applescript.js";

const args = process.argv.slice(2);
const type = getArg(args, "type") ?? "audio";

const menuItems = {
  audio: "New Audio Track",
  instrument: "New Software Instrument Track",
  "session-player": "New Session Player SI Track...",
};

const menuLabel = menuItems[type];
if (!menuLabel) {
  console.error(
    `--type must be one of: ${Object.keys(menuItems).join(", ")}`
  );
  process.exit(1);
}

runAppleScript([
  `tell application "System Events"`,
  `  tell process "Logic Pro"`,
  `    click menu item "${menuLabel}" of menu 1 of menu bar item "Track" of menu bar 1`,
  `  end tell`,
  `end tell`,
]);

console.log(JSON.stringify({ ok: true, type, menuItem: menuLabel }, null, 2));

function getArg(argv, name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= argv.length) return undefined;
  return argv[idx + 1];
}
