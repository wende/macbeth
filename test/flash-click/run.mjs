// Flash-click integration harness (LOCAL macOS ONLY — cannot run in CI).
//
// Requires:
//   - macOS 14+ GUI session with Accessibility permission granted to the daemon.
//   - The daemon + client built (./scripts/build-daemon.sh && cd client && npm run build).
//   - FlashClickTestApp running:  swift test/flash-click/TestApp.swift
//   - TextEdit installed (used as the "previous frontmost app" for restoration).
//
// Run:  node test/flash-click/run.mjs
//
// It exercises the five scenarios from the flash-click spec and prints PASS/FAIL
// for each. It asserts on observable effects (click counters in the window
// title, frontmost app, minimized state) rather than internals.

import { MacbethClient } from "../../client/dist/index.js";

const TEST_APP = "FlashClickTestApp";
let passes = 0;
let failures = 0;

function check(name, cond, detail = "") {
  if (cond) {
    passes++;
    console.log(`  ✅ ${name}`);
  } else {
    failures++;
    console.log(`  ❌ ${name} ${detail}`);
  }
}

const client = new MacbethClient({ verbose: true });

// --- helpers -------------------------------------------------------------

/** Read the testapp window title and parse the two click counters. */
async function readCounters(app) {
  const info = await app.locator({ role: "window" }).getInfo();
  const m = /canvas:(\d+) button:(\d+)/.exec(info.title ?? "");
  if (!m) throw new Error(`Could not parse counters from title: "${info.title}"`);
  return { canvas: Number(m[1]), button: Number(m[2]) };
}

/** Name of the current frontmost app, via the daemon (no osascript spawn). */
async function frontmostApp() {
  return (
    await client.runAppleScript(
      'tell application "System Events" to get name of first application process whose frontmost is true'
    )
  ).trim();
}

/** Whether the testapp's first window is minimized. */
async function isMinimized() {
  const out = await client.runAppleScript(
    `tell application "System Events" to get value of attribute "AXMinimized" of window 1 of process "${TEST_APP}"`
  );
  return out.trim() === "true";
}

async function activateTextEdit() {
  await client.runAppleScript('tell application "TextEdit" to activate');
  // Give the activation a moment to settle before we snapshot "previous app".
  await new Promise((r) => setTimeout(r, 400));
}

// --- scenarios -----------------------------------------------------------

async function main() {
  const app = await client.connect(TEST_APP);

  // 1. auto strategy escalates to flash on an AXPress-less view.
  console.log("\n[1] auto strategy escalates to flash (canvas has no AXPress)");
  {
    const before = await readCounters(app);
    await app.locator({ role: "group", identifier: "canvas" }).click();
    await new Promise((r) => setTimeout(r, 300));
    const after = await readCounters(app);
    check(
      "canvas click registered (only possible via flash — AXPress unavailable)",
      after.canvas === before.canvas + 1,
      `before=${before.canvas} after=${after.canvas}`
    );
  }

  // 2. Restoration: TextEdit frontmost before, restored after; its window unchanged.
  console.log("\n[2] restoration returns focus to the previous app");
  {
    await activateTextEdit();
    const beforeFront = await frontmostApp();
    check("TextEdit is frontmost before the flash", beforeFront === "TextEdit", `got "${beforeFront}"`);
    await app.locator({ role: "group", identifier: "canvas" }).click({ strategy: "flash" });
    await new Promise((r) => setTimeout(r, 400));
    const afterFront = await frontmostApp();
    check("TextEdit is frontmost again after the flash", afterFront === "TextEdit", `got "${afterFront}"`);
  }

  // 3. Minimized target: flash un-minimizes, clicks, re-minimizes.
  console.log("\n[3] minimized target: click registers and window is re-minimized");
  {
    await client.runAppleScript(
      `tell application "System Events" to set value of attribute "AXMinimized" of window 1 of process "${TEST_APP}" to true`
    );
    await new Promise((r) => setTimeout(r, 500));
    check("window is minimized before the flash", await isMinimized(), "expected minimized");
    const before = await readCounters(app);
    await app.locator({ role: "group", identifier: "canvas" }).click({ strategy: "flash" });
    await new Promise((r) => setTimeout(r, 500));
    const after = await readCounters(app);
    check("canvas click registered while minimized", after.canvas === before.canvas + 1, `before=${before.canvas} after=${after.canvas}`);
    check("window is re-minimized after the flash", await isMinimized(), "expected re-minimized");
  }

  // 4. strategy: "flash" forced on a normal button.
  console.log('\n[4] strategy "flash" forced on a normal AXPress-capable button');
  {
    const before = await readCounters(app);
    await app.locator({ role: "button", title: "Normal Button" }).click({ strategy: "flash" });
    await new Promise((r) => setTimeout(r, 300));
    const after = await readCounters(app);
    check("button click registered via forced flash", after.button === before.button + 1, `before=${before.button} after=${after.button}`);
  }

  // 5. Regression: plain AXPress path untouched for the native happy path.
  console.log("\n[5] regression: default (auto → ax) still drives a normal button");
  {
    const before = await readCounters(app);
    await app.locator({ role: "button", title: "Normal Button" }).click(); // default auto → AXPress
    await new Promise((r) => setTimeout(r, 200));
    const after = await readCounters(app);
    check("button click registered via AXPress (no focus steal)", after.button === before.button + 1, `before=${before.button} after=${after.button}`);
  }

  console.log(`\n${failures === 0 ? "ALL PASS" : "FAILURES"}: ${passes} passed, ${failures} failed`);
  await client.close();
  process.exit(failures === 0 ? 0 : 1);
}

main().catch(async (err) => {
  console.error("Harness error:", err);
  try { await client.close(); } catch {}
  process.exit(1);
});
