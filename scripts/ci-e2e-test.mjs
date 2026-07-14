#!/usr/bin/env node
//
// ci-e2e-test.mjs — end-to-end smoke test for the Macbeth CI prototype.
//
// This script exercises the REAL Macbeth stack (daemon + RPC + AX). It must
// not call any AX API directly. If it cannot talk to the daemon, or if any
// AX-derived state diverges from the expected value, it exits non-zero with
// diagnostic output.
//
// Usage:
//   node scripts/ci-e2e-test.mjs \
//     --daemon /path/to/macbethd \
//     --app    "MacbethCIHarness" \
//     --socket /tmp/macbeth-ci.sock
//
// Note: --app is the macOS process name (NSRunningApplication.localizedName
// for our test harness is "MacbethCIHarness", not the window title).

import { MacbethClient } from "../client/dist/index.js";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const args = parseArgs(process.argv.slice(2));
const daemonPath = required(args, "daemon");
const appName = required(args, "app");
const socketPath = args.socket || "/tmp/macbeth-ci-e2e.sock";

const log = (...a) => console.log("[ci-e2e]", ...a);
const fail = (msg, extra) => {
  console.error(`[ci-e2e] FAIL: ${msg}`);
  if (extra) console.error(extra);
  process.exit(1);
};

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k.startsWith("--")) {
      out[k.slice(2)] = argv[i + 1];
      i++;
    }
  }
  return out;
}
function required(o, k) {
  if (!o[k]) {
    console.error(`Missing --${k}`);
    process.exit(2);
  }
  return o[k];
}

async function poll(label, fn, { timeoutMs = 15_000, intervalMs = 500 } = {}) {
  const deadline = Date.now() + timeoutMs;
  let lastErr;
  while (Date.now() < deadline) {
    try {
      const v = await fn();
      if (v) return v;
    } catch (e) {
      lastErr = e;
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`Timed out waiting for: ${label}${lastErr ? ` (${lastErr.message})` : ""}`);
}

(async () => {
  log(`daemon=${daemonPath} app=${JSON.stringify(appName)} socket=${socketPath}`);

  const client = new MacbethClient({ daemonPath, socketPath });

  let app;
  try {
    log("connecting to app via MacbethClient.connect()...");
    app = await poll("app connectable", () => client.connect(appName), {
      timeoutMs: 30_000,
    });
    log(`connected: name=${app.name} pid=${app.pid} bundleId=${app.bundleId}`);

    // The window title and the process name are intentionally different
    // so we can tell apart "found the process" from "found the window".
    log("waiting for window titled 'Macbeth CI Harness'...");
    const window = await poll("window discoverable", () =>
      app.window("Macbeth CI Harness").waitFor({ timeout: 5_000 })
    );
    log(`window handleId=${window.handleId}`);

    // Read the initial text-field value via the real AX path.
    // The harness's NSTextField exposes identifier="ci-name-input" but
    // no title (an NSTextField without an explicit label has no AXTitle).
    log("reading initial value of ci-name-input...");
    const nameField = app
      .window("Macbeth CI Harness")
      .locator({ role: "text_field", identifier: "ci-name-input" });
    const initial = await poll("name field has value", () => nameField.getText(), {
      timeoutMs: 10_000,
    });
    log(`initial value: ${JSON.stringify(initial)}`);
    if (initial !== "initial-name") {
      fail(`expected initial name field value 'initial-name', got ${JSON.stringify(initial)}`);
    }

    // Fill a new value through the daemon's fill RPC (no direct AX).
    const newName = `ci-${Date.now()}`;
    log(`filling name field with ${newName}`);
    await nameField.fill(newName);

    const filledValue = await poll("name field updated", () => nameField.getText());
    if (filledValue !== newName) {
      fail(`expected name field to be ${newName}, got ${JSON.stringify(filledValue)}`);
    }
    log(`name field now: ${JSON.stringify(filledValue)}`);

    // Click the submit button via the daemon's click RPC.
    log("clicking ci-submit-btn...");
    await app
      .window("Macbeth CI Harness")
      .locator({ role: "button", title: "Submit", identifier: "ci-submit-btn" })
      .click();

    // Verify the status label changed. The harness sets it to
    // "submitted:<name>" when the button is pressed.
    const statusLabel = app
      .window("Macbeth CI Harness")
      .locator({ role: "text", identifier: "ci-status-label" });
    const expectedStatus = `submitted:${newName}`;
    log(`waiting for status label to read ${JSON.stringify(expectedStatus)}...`);
    const status = await poll("status label updated", async () => {
      const s = await statusLabel.getText();
      return s === expectedStatus ? s : null;
    }, { timeoutMs: 10_000 });
    log(`status label now: ${JSON.stringify(status)}`);

    log("ALL CHECKS PASSED");
    writeResultFile("pass", { app: appName, pid: app.pid, status, filledValue });
  } catch (e) {
    writeResultFile("fail", { error: e.message, stack: e.stack });
    fail(e.message, e.stack);
  } finally {
    try { await client.close(); } catch {}
  }
})();

function writeResultFile(outcome, payload) {
  try {
    const dir = mkdtempSync(join(tmpdir(), "macbeth-ci-e2e-"));
    writeFileSync(join(dir, "result.json"), JSON.stringify({ outcome, ...payload, ts: new Date().toISOString() }, null, 2));
    log(`result written to ${dir}/result.json`);
  } catch (e) {
    console.error("[ci-e2e] could not write result file:", e.message);
  }
}