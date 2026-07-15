// Local-only integration test for macbeth's Electron support.
//
// This drives a REAL Electron app (the fixture in ./fixture) and asserts that the
// AX-enablement, readiness polling, and the fill/click strategies actually work
// against Chromium web content. It cannot run in CI: it needs a macOS host with
// Accessibility permissions granted to the launching terminal, and a window server.
//
// Prerequisites:
//   cd client && npm install --force && npm run build
//   cd test-electron/fixture && npm install     # downloads Electron (~100MB)
//
// Run:
//   node client/test-electron/run.mjs
//   (or:  cd client && npm run test:electron)

import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { MacbethClient } from "../dist/client.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok });
  const mark = ok ? "✓" : "✗";
  console.log(`  ${mark} ${name}${detail ? ` — ${detail}` : ""}`);
}

async function main() {
  // Resolve the Electron binary the fixture installed. `require('electron')` in a plain
  // Node context returns the path to the executable.
  let electronPath;
  try {
    electronPath = require(join(__dirname, "fixture", "node_modules", "electron"));
  } catch {
    console.error(
      "Electron not installed for the fixture. Run:\n" +
        "  cd client/test-electron/fixture && npm install\n"
    );
    process.exit(2);
  }

  const userDataDir = mkdtempSync(join(tmpdir(), "macbeth-fixture-"));
  const fixtureDir = join(__dirname, "fixture");

  const child = spawn(electronPath, [fixtureDir, `--user-data-dir=${userDataDir}`], {
    stdio: ["ignore", "pipe", "inherit"],
  });

  // Wait for the fixture to report its PID.
  const pid = await new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error("fixture did not start in 15s")), 15_000);
    child.stdout.on("data", (d) => {
      buf += d.toString();
      const m = buf.match(/FIXTURE_PID=(\d+)/);
      if (m) {
        clearTimeout(timer);
        resolve(Number(m[1]));
      }
    });
    child.on("exit", (code) => reject(new Error(`fixture exited early (code ${code})`)));
  });

  const client = new MacbethClient({ verbose: true });
  try {
    // 1. connect → tree contains AXWebArea within the readiness timeout.
    const app = await client.connect(pid, { readyTimeoutMs: 5000 });
    check("connect reports electron runtime", app.runtime === "electron", `runtime=${app.runtime}`);

    const tree = await app.queryTree({ maxDepth: 12 });
    check("query_tree contains web_area", /web_area/.test(tree));

    const web = app.window("MacbethFixture").webArea();

    // 2. click on the fixture button → counter increments (assert via AX heading).
    const countBefore = (await web.heading().getInfo()).title; // "Count: 0"
    await web.button("Increment").click();
    await new Promise((r) => setTimeout(r, 300));
    const countAfter = (await web.heading().getInfo()).title;
    check("click increments counter", countBefore !== countAfter, `${countBefore} → ${countAfter}`);

    // 3. fill on the input → app STATE reflects the text (the mirror heading only
    //    updates on real input events, so this proves the keyboard-synthesis fallback
    //    fired, not just an AX value write). Assert via the tree text read through AX.
    await web.textField().fill("hello world");
    await new Promise((r) => setTimeout(r, 300));
    const mirror = await app.queryTree({ maxDepth: 12 });
    check("fill (auto) updates React-style state", mirror.includes("Mirror: hello world"), "checked mirror heading");

    // 4a. forced keyboard strategy.
    await web.textField().fill("typed via keyboard", { strategy: "keyboard" });
    await new Promise((r) => setTimeout(r, 300));
    const kbMirror = await app.queryTree({ maxDepth: 12 });
    check("fill strategy=keyboard updates state", kbMirror.includes("Mirror: typed via keyboard"), "checked mirror heading");

    // 4b. forced mouse strategy on the button.
    const beforeMouse = (await web.heading().getInfo()).title;
    await web.button("Increment").click({ strategy: "mouse" });
    await new Promise((r) => setTimeout(r, 300));
    const afterMouse = (await web.heading().getInfo()).title;
    check("click strategy=mouse increments counter", beforeMouse !== afterMouse, `${beforeMouse} → ${afterMouse}`);
  } finally {
    await client.close();
    child.kill("SIGTERM");
    try {
      rmSync(userDataDir, { recursive: true, force: true });
    } catch {
      /* best effort */
    }
  }

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  process.exit(failed.length === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error("Electron integration test crashed:", err);
  process.exit(1);
});
