#!/usr/bin/env node

// README presentation demo — visual chrome only.
//
// Shows what an external screen recording can see: window outline glow,
// synthetic pointer travel, form changes, and screenshot scan/snap.
// Fixtures only (Macbeth TestApp + Electron testapp). No invisible feature
// matrix (wait_for / query_tree / strategy variants / OCR).
//
// Recording recipe:
//   1. Clean desktop; hide this terminal (or move it off the capture crop).
//   2. Start a display-region recording that frames both fixture windows.
//   3. npm run demo:presentation
//   4. Stop after the “Recording complete — stop capture” line.
//   5. Export ~800×476 (or 16:9) GIF for the README when ready.
//
// Node subprocesses are permitted only during bootstrap. After MCP connects,
// every app operation goes through MCP tools.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const NATIVE_BUNDLE = join(ROOT, "test/test-harness/.build/MacbethTestApp.app");
const ELECTRON_APP = join(ROOT, "test/electron-testapp");
const ELECTRON_BUNDLE = join(ELECTRON_APP, "node_modules/electron/dist/Electron.app");
const MCP_ENTRY = join(ROOT, "client/bin/macbeth.mjs");
const BUILD_TMP = join(ROOT, ".tmp");
const SWIFT_MODULE_CACHE = join(BUILD_TMP, "swift-module-cache");
const DEMO_RUNTIME = join(BUILD_TMP, "mcp-presentation-runtime");

// Stage: two windows side-by-side for an 800×476-style crop.
const NATIVE_POSITION = "{40, 70}";
const NATIVE_SIZE = "{560, 640}";
const ELECTRON_POSITION = "{620, 70}";
const ELECTRON_SIZE = "{480, 560}";

const args = parseArgs(process.argv.slice(2));
/** Pause after each on-screen beat (pointer settles, form updates). */
const beatMs = args.fast ? 0 : args.delayMs ?? 900;
/** Brief hold between pointer targets within a multi-action beat. */
const holdMs = args.fast ? 0 : Math.round(beatMs * 0.5);
/** Hold when switching frontmost app. */
const sectionHoldMs = args.fast ? 0 : Math.max(700, Math.round(beatMs * 0.8));
/** Final hold so the capture snap and filled state read on camera. */
const outroHoldMs = args.fast ? 0 : 2_200;

const outcomes = [];
const artifacts = [];
const startedAt = Date.now();
let mcpConnected = false;
let client;
let transport;
let nativePid;
let electronPid;
let cleanupStarted = false;
let signalShutdownStarted = false;
let originalFrontmostPid;
const baselineNativePids = new Set();
const baselineElectronPids = new Set();

const APP_NATIVE = "Macbeth TestApp";
const q = (role, identifier, extra = {}) => [{ role, identifier, ...extra }];

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--fast") parsed.fast = true;
    else if (value === "--delay-ms") parsed.delayMs = Number(argv[++index]);
    else if (value.startsWith("--delay-ms=")) parsed.delayMs = Number(value.split("=")[1]);
    else if (value === "--help" || value === "-h") parsed.help = true;
    else throw new Error(`Unknown argument: ${value}`);
  }
  if (parsed.delayMs !== undefined && (!Number.isFinite(parsed.delayMs) || parsed.delayMs < 0)) {
    throw new Error("--delay-ms must be a non-negative number");
  }
  return parsed;
}

function usage() {
  console.log(`Usage: npm run demo:presentation -- [options]

README-length (~20–30s) visual demo: glow, synthetic pointer, fills/clicks,
and screenshot scan/snap. Fixtures only. Keep the terminal off the capture crop.

Options:
  --delay-ms <ms>  Pause after each beat (default: 900)
  --fast           Continuous presentation with no pacing pauses
  --help           Show this help`);
}

if (args.help) {
  usage();
  process.exit(0);
}

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}

function runBootstrap(command, commandArgs, options = {}) {
  if (mcpConnected) {
    throw new Error(`Direct process execution is forbidden after MCP connection: ${command}`);
  }
  execFileSync(command, commandArgs, {
    cwd: ROOT,
    stdio: "inherit",
    env: {
      ...process.env,
      TMPDIR: BUILD_TMP,
      CLANG_MODULE_CACHE_PATH: SWIFT_MODULE_CACHE,
      SWIFTPM_MODULECACHE_OVERRIDE: SWIFT_MODULE_CACHE,
    },
    ...options,
  });
}

function textOf(result) {
  return (result?.content ?? [])
    .filter((item) => item.type === "text")
    .map((item) => item.text)
    .join("\n");
}

function jsonOf(result) {
  const text = textOf(result);
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`Expected JSON tool output, received: ${text.slice(0, 300)}`);
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

/** Silent MCP call — no console noise during the recording window. */
async function callTool(name, toolArgs = {}, options = {}) {
  const result = await client.callTool({ name, arguments: toolArgs });
  const text = textOf(result);
  if (result.isError) throw new Error(text || `${name} returned an MCP error`);
  if (!options.noDelay && beatMs > 0) await sleep(beatMs);
  return result;
}

async function beat(name, action) {
  const stepStarted = Date.now();
  console.log(`  • ${name}`);
  try {
    const value = await action();
    const result = { name, status: "pass", durationMs: Date.now() - stepStarted, value };
    outcomes.push(result);
    return result;
  } catch (error) {
    const result = {
      name,
      status: "fail",
      durationMs: Date.now() - stepStarted,
      detail: error instanceof Error ? error.message : String(error),
    };
    outcomes.push(result);
    console.error(`  ✗ ${name}: ${result.detail}`);
    return result;
  }
}

async function pollTool(name, toolArgs, predicate, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  let lastText = "";
  while (Date.now() < deadline) {
    try {
      const result = await callTool(name, toolArgs, { noDelay: true });
      lastText = textOf(result);
      if (predicate(lastText, result)) return result;
    } catch (error) {
      lastText = error instanceof Error ? error.message : String(error);
    }
    await sleep(250);
  }
  throw new Error(`Timed out waiting for ${name}: ${lastText.slice(0, 200)}`);
}

function pidFromConnect(result) {
  const match = textOf(result).match(/pid:\s*(\d+)/);
  if (!match) throw new Error(`Could not parse PID from: ${textOf(result)}`);
  return Number(match[1]);
}

/** MCP connect_app success text (no longer contains the literal "Connected to"). */
function isConnectAppSuccess(text) {
  return /\bpid:\s*\d+/.test(text) && /\bhandle:\s*\S+/.test(text) && !/^Error\b/i.test(text);
}

function pidsForListedName(text, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return [...text.matchAll(new RegExp(`^${escaped} \\(pid: (\\d+),`, "gm"))]
    .map((match) => Number(match[1]));
}

/** Only the PIDs this script launched — never every process named Electron. */
function ownedFixturePids() {
  return [nativePid, electronPid].filter((pid) => Number.isFinite(pid));
}

function runningOwnedFixturePids(appListText) {
  return ownedFixturePids().filter((pid) => new RegExp(`\\(pid: ${pid},`).test(appListText));
}

async function layoutFixtureWindow(pid, position, size, { frontmost = false } = {}) {
  await pollTool(
    "run_applescript",
    {
      source: `tell application "System Events"
        tell (first application process whose unix id is ${pid})
          set position of window 1 to ${position}
          set size of window 1 to ${size}
          ${frontmost ? "set frontmost to true" : ""}
        end tell
        return "ready"
      end tell`,
    },
    (text) => text.trim() === "ready",
    15_000
  );
}

async function setFrontmost(pid) {
  await callTool("run_applescript", {
    source: `tell application "System Events"
      set frontmost of first application process whose unix id is ${pid} to true
      return "ready"
    end tell`,
  }, { noDelay: true });
  if (sectionHoldMs > 0) await sleep(sectionHoldMs);
}

async function captureInitialState() {
  const apps = textOf(await callTool("list_apps", {}, { noDelay: true }));
  for (const pid of pidsForListedName(apps, APP_NATIVE)) baselineNativePids.add(pid);
  for (const pid of pidsForListedName(apps, "Electron")) baselineElectronPids.add(pid);

  const frontmost = textOf(await callTool("run_applescript", {
    interaction: "read_only",
    source: `tell application "System Events"
      return unix id of first application process whose frontmost is true
    end tell`,
  }, { noDelay: true }));
  const parsedPid = Number(frontmost.trim());
  if (Number.isFinite(parsedPid)) originalFrontmostPid = parsedPid;
}

async function prepare() {
  console.log("Preparing daemon, client, and demo apps…");
  mkdirSync(SWIFT_MODULE_CACHE, { recursive: true });
  mkdirSync(DEMO_RUNTIME, { recursive: true });
  if (!existsSync(join(ROOT, "node_modules/@modelcontextprotocol/sdk/package.json"))) {
    runBootstrap("npm", ["install"]);
  }
  if (!existsSync(ELECTRON_BUNDLE)) {
    runBootstrap("npm", ["ci", "--prefix", "test/electron-testapp"]);
  }
  runBootstrap(join(ROOT, "scripts/build-daemon.sh"), []);
  runBootstrap("npm", ["--prefix", "client", "run", "build"]);
  runBootstrap(join(ROOT, "scripts/build-test-harness.sh"), []);
  assert(existsSync(NATIVE_BUNDLE), `Native fixture was not built: ${NATIVE_BUNDLE}`);
  assert(existsSync(ELECTRON_BUNDLE), `Electron fixture is unavailable: ${ELECTRON_BUNDLE}`);
}

async function connectMcp() {
  const [{ Client }, { StdioClientTransport }] = await Promise.all([
    import("@modelcontextprotocol/sdk/client/index.js"),
    import("@modelcontextprotocol/sdk/client/stdio.js"),
  ]);
  client = new Client({ name: "macbeth-presentation-demo", version: "1.0.0" });
  transport = new StdioClientTransport({
    command: process.execPath,
    args: [MCP_ENTRY],
    cwd: ROOT,
    stderr: "inherit",
    env: {
      ...process.env,
      TMPDIR: DEMO_RUNTIME,
    },
  });
  await client.connect(transport);
  mcpConnected = true;
}

/**
 * Launch and stage both fixtures without connect_app.
 * Connecting is part of the recorded storyboard so the outline appears on camera.
 */
async function stageApps() {
  await callTool("run_applescript", {
    source: `do shell script "/usr/bin/open -g -n " & quoted form of "${NATIVE_BUNDLE}" & " --args --presentation"`,
  }, { noDelay: true });
  await pollTool("list_apps", {}, (text) => {
    const launchedPid = pidsForListedName(text, APP_NATIVE)
      .find((pid) => !baselineNativePids.has(pid));
    if (!launchedPid) return false;
    nativePid = launchedPid;
    return true;
  });

  await callTool("run_applescript", {
    source: `do shell script "/usr/bin/open -g -n -a " & quoted form of "${ELECTRON_BUNDLE}" & " --args " & quoted form of "${ELECTRON_APP}"`,
  }, { noDelay: true });
  await pollTool("list_apps", {}, (text) => {
    const launchedPid = pidsForListedName(text, "Electron")
      .find((pid) => !baselineElectronPids.has(pid));
    if (!launchedPid) return false;
    electronPid = launchedPid;
    return true;
  });

  // Layout before connect so the first outline sits on the final frame.
  // Native last + frontmost so both windows are idle and ready for the crop.
  await layoutFixtureWindow(electronPid, ELECTRON_POSITION, ELECTRON_SIZE);
  await layoutFixtureWindow(nativePid, NATIVE_POSITION, NATIVE_SIZE, { frontmost: true });
  if (holdMs > 0) await sleep(Math.max(holdMs, 400));
}

async function runPresentation() {
  // Beat 1 — outline appears on connect (native frontmost).
  await beat("Outline native window", async () => {
    const nativeConnection = await pollTool(
      "connect_app",
      { pid: nativePid },
      isConnectAppSuccess
    );
    nativePid = pidFromConnect(nativeConnection);
    // Electron connect while native stays frontmost: no competing outline.
    const electronConnection = await pollTool(
      "connect_app",
      { pid: electronPid, readyTimeoutMs: 8_000 },
      isConnectAppSuccess,
      20_000
    );
    electronPid = pidFromConnect(electronConnection);
    if (beatMs > 0) await sleep(beatMs);
  });

  // Beat 2 — pointer + fills on native form.
  await beat("Fill native name and email", async () => {
    await callTool("fill", {
      app: nativePid,
      query: q("text_field", "name-input"),
      value: "Lady Macbeth",
    }, { noDelay: true });
    if (holdMs > 0) await sleep(holdMs);
    await callTool("fill", {
      app: nativePid,
      query: q("text_field", "email-input"),
      value: "lady@dunsinane.example",
    }, { noDelay: true });
    if (beatMs > 0) await sleep(beatMs);
  });

  // Beat 3 — checkbox + Submit (visible state changes).
  await beat("Click checkbox and Submit", async () => {
    await callTool("click", {
      app: nativePid,
      query: q("checkbox", "notifications-checkbox"),
    }, { noDelay: true });
    if (holdMs > 0) await sleep(holdMs);
    await callTool("click", {
      app: nativePid,
      query: q("button", "submit-btn"),
    }, { noDelay: true });
    if (beatMs > 0) await sleep(beatMs);
  });

  // Beat 4 — hand off to Electron: outline + form + Submit.
  await beat("Fill and submit Electron form", async () => {
    await setFrontmost(electronPid);
    await callTool("fill", {
      app: electronPid,
      query: [{ role: "text_field", title: "Name:" }],
      value: "Electron Demo",
    }, { noDelay: true });
    if (holdMs > 0) await sleep(holdMs);
    await callTool("click", {
      app: electronPid,
      query: [{ role: "button", title: "Submit" }],
    }, { noDelay: true });
    if (beatMs > 0) await sleep(beatMs);
  });

  // Beat 5 — hero capture animation on the native window.
  await beat("Screenshot native window", async () => {
    await setFrontmost(nativePid);
    const saved = jsonOf(await callTool("screenshot", { app: nativePid }, { noDelay: true }));
    assert(saved.path && saved.width > 0 && saved.height > 0, "Screenshot metadata was incomplete");
    artifacts.push(saved.path);
    // Capture overlay already presents ~0.95s; beat pause lets the snap read.
    if (beatMs > 0) await sleep(beatMs);
  });

  // Beat 6 — hold for the outro frame.
  await beat("Outro hold", async () => {
    if (outroHoldMs > 0) await sleep(outroHoldMs);
  });
}

async function cleanup() {
  if (cleanupStarted) return;
  cleanupStarted = true;
  const cleanupStartedAt = Date.now();
  const cleanupErrors = [];

  if (mcpConnected) {
    const fixturePids = ownedFixturePids();

    if (fixturePids.length > 0) {
      try {
        await callTool("run_applescript", {
          source: `do shell script "/bin/kill -TERM ${fixturePids.join(" ")} 2>/dev/null || true"`,
        }, { noDelay: true });
      } catch (error) {
        cleanupErrors.push(`could not terminate fixtures: ${error instanceof Error ? error.message : String(error)}`);
      }

      const deadline = Date.now() + 3_000;
      let remaining = new Set(fixturePids);
      while (remaining.size > 0 && Date.now() < deadline) {
        try {
          const apps = textOf(await callTool("list_apps", {}, { noDelay: true }));
          remaining = new Set(runningOwnedFixturePids(apps));
        } catch (error) {
          cleanupErrors.push(`could not verify fixture exit: ${error instanceof Error ? error.message : String(error)}`);
          break;
        }
        if (remaining.size > 0) await sleep(100);
      }

      if (remaining.size > 0) {
        try {
          await callTool("run_applescript", {
            source: `do shell script "/bin/kill -KILL ${[...remaining].join(" ")} 2>/dev/null || true"`,
          }, { noDelay: true });
        } catch (error) {
          cleanupErrors.push(`could not force-close fixtures: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
    }

    if (Number.isFinite(originalFrontmostPid)) {
      try {
        await callTool("run_applescript", {
          source: `tell application "System Events"
            if exists (first application process whose unix id is ${originalFrontmostPid}) then
              set frontmost of first application process whose unix id is ${originalFrontmostPid} to true
            end if
          end tell`,
        }, { noDelay: true });
      } catch (error) {
        cleanupErrors.push(`could not restore the foreground app: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }

  try {
    await client?.close();
  } catch (error) {
    try {
      await transport?.close();
    } catch (transportError) {
      cleanupErrors.push(`could not close MCP transport: ${transportError instanceof Error ? transportError.message : String(transportError)}`);
    }
    if (!transport) {
      cleanupErrors.push(`could not close MCP client: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  mcpConnected = false;

  const cleanupResult = {
    name: "Restore pre-demo state",
    status: cleanupErrors.length === 0 ? "pass" : "fail",
    durationMs: Date.now() - cleanupStartedAt,
    ...(cleanupErrors.length > 0 ? { detail: cleanupErrors.join("; ") } : {}),
  };
  outcomes.push(cleanupResult);
  const mark = cleanupResult.status === "pass" ? "✓" : "✗";
  console.log(`  ${mark} ${cleanupResult.name} (${cleanupResult.durationMs}ms)`);
  if (cleanupResult.detail) console.error(`    ${cleanupResult.detail}`);
}

async function shutdownFromSignal(signal, exitCode) {
  if (signalShutdownStarted) return;
  signalShutdownStarted = true;
  console.error(`\n${signal} received; closing MCP transport and overlays…`);
  await cleanup();
  process.exit(exitCode);
}

process.once("SIGINT", () => { void shutdownFromSignal("SIGINT", 130); });
process.once("SIGTERM", () => { void shutdownFromSignal("SIGTERM", 143); });

function printSummary() {
  const totalMs = Date.now() - startedAt;
  const counts = { pass: 0, fail: 0, skip: 0 };
  console.log("\n━━ Presentation summary ━━");
  for (const result of outcomes) {
    counts[result.status] = (counts[result.status] ?? 0) + 1;
    const mark = result.status === "pass" ? "✓" : result.status === "fail" ? "✗" : "↷";
    const detail = result.detail ? ` — ${result.detail}` : "";
    console.log(`${mark} ${result.name} [${result.status}, ${result.durationMs}ms]${detail}`);
  }
  if (artifacts.length > 0) {
    console.log("\nScreenshot artifacts:");
    for (const path of artifacts) console.log(`  ${path}`);
  }
  console.log(`\n${counts.pass ?? 0} passed, ${counts.fail ?? 0} failed in ${(totalMs / 1000).toFixed(1)}s`);
  return counts.fail ?? 0;
}

async function main() {
  await prepare();
  await connectMcp();
  await captureInitialState();

  const stage = await beat("Stage native and Electron fixtures", stageApps);
  if (stage.status !== "pass") {
    outcomes.push({
      name: "Presentation",
      status: "skip",
      durationMs: 0,
      detail: "fixtures did not stage",
    });
    return;
  }

  if (!args.fast) {
    console.log("\n━━ Hide this terminal, start screen capture on the two windows ━━");
    console.log("Recording starts in…");
    for (const count of [3, 2, 1]) {
      console.log(`  ${count}`);
      await sleep(1000);
    }
    console.log("  RECORDING — action begins\n");
  }

  await runPresentation();

  if (!args.fast) {
    console.log("\n━━ Recording complete — stop capture ━━\n");
  }
}

let fatalError;
try {
  await main();
} catch (error) {
  fatalError = error;
  outcomes.push({
    name: "Presentation runner",
    status: "fail",
    durationMs: 0,
    detail: error instanceof Error ? error.message : String(error),
  });
  console.error(error);
} finally {
  await cleanup();
}

const failures = printSummary();
if (fatalError || failures > 0) process.exitCode = 1;
