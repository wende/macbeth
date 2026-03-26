// @name open-url
// @description Opens a URL in Safari and waits for it to load
// @usage node scripts/open-url.mjs <url>

import { execSync } from "node:child_process";
import { connect } from "macbeth";

const url = process.argv[2];
if (!url) {
  console.error("Usage: node scripts/open-url.mjs <url>");
  process.exit(1);
}

execSync(`open -a Safari "${url}"`);

const app = await connect("Safari");

// Wait for the web_area to appear (page loaded)
const webArea = app
  .window()
  .locator({ role: "tab_group" })
  .locator({ role: "group" })
  .locator({ role: "scroll_area" })
  .locator({ role: "web_area" });

await webArea.waitFor({ timeout: 15000 });

const tree = await app.queryTree({ maxDepth: 3 });
const titleMatch = tree.match(/\[window "(.+?)"/);
console.log(`Loaded: ${titleMatch?.[1] ?? url}`);
