#!/usr/bin/env node

// Background-interruption demo.
//
// Runs the same fixture/tool feature set as demo:presentation while keeping the
// app that launched this command frontmost. A read-only NSWorkspace watcher
// records every application activation, so brief focus steals that are restored
// before a tool returns are still included in the summary.
//
// All operations on Macbeth TestApp and Electron go through MCP tools. The
// watcher observes focus changes only; it never manipulates either fixture.

import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const NATIVE_BUNDLE = join(ROOT, "test/test-harness/.build/MacbethTestApp.app");
const ELECTRON_APP = join(ROOT, "test/electron-testapp");
const ELECTRON_BUNDLE = join(ELECTRON_APP, "node_modules/electron/dist/Electron.app");
const MCP_ENTRY = join(ROOT, "client/bin/macbeth.mjs");
const BUILD_TMP = join(ROOT, ".tmp");
const SWIFT_MODULE_CACHE = join(BUILD_TMP, "swift-module-cache");
const DEMO_RUNTIME = join(BUILD_TMP, "mcp-background-runtime");
const WATCHER_SOURCE = join(ROOT, "scripts/watch-frontmost.swift");
const WATCHER_BINARY = join(BUILD_TMP, "watch-frontmost");

const NATIVE_POSITION = "{40, 70}";
const NATIVE_SIZE = "{560, 640}";
const ELECTRON_POSITION = "{620, 70}";
const ELECTRON_SIZE = "{480, 560}";
const APP_NATIVE = "Macbeth TestApp";
const q = (role, identifier, extra = {}) => [{ role, identifier, ...extra }];

const args = parseArgs(process.argv.slice(2));
const actionHoldMs = args.fast ? 0 : args.delayMs ?? 900;
const measurementGraceMs = 180;

const outcomes = [];
const measurements = [];
const artifacts = [];
const focusEvents = [];
const startedAt = Date.now();
const baselineNativePids = new Set();
const baselineElectronPids = new Set();

let client;
let transport;
let watcher;
let watcherBuffer = "";
let watcherReady;
let watcherReadyResolve;
let watcherReadyReject;
let mcpConnected = false;
let cleanupStarted = false;
let signalShutdownStarted = false;
let sentinelPid;
let sentinelName = "foreground app";
let nativePid;
let electronPid;

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
  console.log(`Usage: npm run demo:background -- [options]

Runs the demo:presentation tool set against backgrounded native and Electron
fixtures, then reports how often and for how long your foreground app was
interrupted.

Options:
  --delay-ms <ms>  Pause between measured actions (default: 900)
  --fast           Run actions continuously with no presentation pauses
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
    throw new Error(`Direct bootstrap execution is forbidden after MCP connection: ${command}`);
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

async function callTool(name, toolArgs = {}) {
  const result = await client.callTool({ name, arguments: toolArgs });
  const text = textOf(result);
  if (result.isError) throw new Error(text || `${name} returned an MCP error`);
  return result;
}

async function pollTool(name, toolArgs, predicate, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  let lastText = "";
  while (Date.now() < deadline) {
    try {
      const result = await callTool(name, toolArgs);
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

async function getFrontmostPid() {
  const result = await callTool("run_applescript", {
    interaction: "read_only",
    source: `tell application "System Events"
      return unix id of first application process whose frontmost is true
    end tell`,
  });
  const pid = Number(textOf(result).trim());
  if (!Number.isFinite(pid)) {
    throw new Error(`Could not parse frontmost PID from: ${textOf(result)}`);
  }
  return pid;
}

async function setFrontmost(pid) {
  await callTool("run_applescript", {
    source: `tell application "System Events"
      if exists (first application process whose unix id is ${pid}) then
        set frontmost of first application process whose unix id is ${pid} to true
        return "ready"
      end if
      return "missing"
    end tell`,
  });
}

async function ensureSentinelFrontmost() {
  await setFrontmost(sentinelPid);
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const current = await getFrontmostPid();
    if (current === sentinelPid) return;
    await setFrontmost(sentinelPid);
    await sleep(50);
  }
  throw new Error(`Could not restore ${sentinelName} (pid ${sentinelPid}) to the foreground`);
}

async function layoutFixtureWindow(pid, position, size) {
  await pollTool(
    "run_applescript",
    {
      source: `tell application "System Events"
        tell (first application process whose unix id is ${pid})
          set position of window 1 to ${position}
          set size of window 1 to ${size}
        end tell
        return "ready"
      end tell`,
    },
    (text) => text.trim() === "ready"
  );
}

function prepare() {
  console.log("Preparing daemon, client, demo apps, and focus watcher…");
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

  const watcherIsFresh =
    existsSync(WATCHER_BINARY) &&
    statSync(WATCHER_BINARY).mtimeMs >= statSync(WATCHER_SOURCE).mtimeMs;
  if (!watcherIsFresh) {
    runBootstrap("swiftc", ["-O", WATCHER_SOURCE, "-o", WATCHER_BINARY]);
  }

  assert(existsSync(NATIVE_BUNDLE), `Native fixture was not built: ${NATIVE_BUNDLE}`);
  assert(existsSync(ELECTRON_BUNDLE), `Electron fixture is unavailable: ${ELECTRON_BUNDLE}`);
  assert(existsSync(WATCHER_BINARY), `Focus watcher was not built: ${WATCHER_BINARY}`);
}

async function connectMcp() {
  const [{ Client }, { StdioClientTransport }] = await Promise.all([
    import("@modelcontextprotocol/sdk/client/index.js"),
    import("@modelcontextprotocol/sdk/client/stdio.js"),
  ]);
  client = new Client({ name: "macbeth-background-demo", version: "1.0.0" });
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

function acceptWatcherChunk(chunk) {
  watcherBuffer += chunk;
  while (watcherBuffer.includes("\n")) {
    const newline = watcherBuffer.indexOf("\n");
    const line = watcherBuffer.slice(0, newline).trim();
    watcherBuffer = watcherBuffer.slice(newline + 1);
    if (!line) continue;
    try {
      const event = JSON.parse(line);
      if (!Number.isFinite(event.timestampMs) || !Number.isFinite(event.pid)) continue;
      focusEvents.push(event);
      watcherReadyResolve?.(event);
      watcherReadyResolve = undefined;
      watcherReadyReject = undefined;
    } catch {
      // Ignore a malformed diagnostic line; the next activation event remains usable.
    }
  }
}

async function startFocusWatcher() {
  watcherReady = new Promise((resolveReady, rejectReady) => {
    watcherReadyResolve = resolveReady;
    watcherReadyReject = rejectReady;
  });
  watcher = spawn(WATCHER_BINARY, [], {
    cwd: ROOT,
    stdio: ["ignore", "pipe", "inherit"],
  });
  watcher.stdout.setEncoding("utf8");
  watcher.stdout.on("data", acceptWatcherChunk);
  watcher.once("error", (error) => watcherReadyReject?.(error));
  watcher.once("exit", (code, signal) => {
    if (watcherReadyReject) {
      watcherReadyReject(new Error(`Focus watcher exited before readiness (${signal ?? code})`));
    }
  });
  const timeout = sleep(5_000).then(() => {
    throw new Error("Timed out waiting for the focus watcher");
  });
  const firstEvent = await Promise.race([watcherReady, timeout]);
  sentinelPid = firstEvent.pid;
  sentinelName = firstEvent.name;
}

async function stopFocusWatcher() {
  if (!watcher) return;
  const runningWatcher = watcher;
  watcher = undefined;
  if (runningWatcher.exitCode !== null || runningWatcher.signalCode !== null) return;
  const exited = new Promise((resolveExit) => runningWatcher.once("exit", resolveExit));
  runningWatcher.kill("SIGTERM");
  await Promise.race([exited, sleep(1_000)]);
}

async function captureInitialState() {
  const apps = textOf(await callTool("list_apps"));
  for (const pid of pidsForListedName(apps, APP_NATIVE)) baselineNativePids.add(pid);
  for (const pid of pidsForListedName(apps, "Electron")) baselineElectronPids.add(pid);
}

async function stageApps() {
  await callTool("run_applescript", {
    source: `do shell script "/usr/bin/open -g -n " & quoted form of "${NATIVE_BUNDLE}" & " --args --presentation"`,
  });
  await pollTool("list_apps", {}, (text) => {
    const launchedPid = pidsForListedName(text, APP_NATIVE)
      .find((pid) => !baselineNativePids.has(pid));
    if (!launchedPid) return false;
    nativePid = launchedPid;
    return true;
  });

  await callTool("run_applescript", {
    // A never-frontmost Chromium window may defer creating its web AX tree even
    // after AXManualAccessibility is set. This Chromium launch switch makes the
    // demo fixture testable without foregrounding it once during setup.
    source: `do shell script "/usr/bin/open -g -n -a " & quoted form of "${ELECTRON_BUNDLE}" & " --args --force-renderer-accessibility " & quoted form of "${ELECTRON_APP}"`,
  });
  await pollTool("list_apps", {}, (text) => {
    const launchedPid = pidsForListedName(text, "Electron")
      .find((pid) => !baselineElectronPids.has(pid));
    if (!launchedPid) return false;
    electronPid = launchedPid;
    return true;
  });

  await layoutFixtureWindow(nativePid, NATIVE_POSITION, NATIVE_SIZE);
  await layoutFixtureWindow(electronPid, ELECTRON_POSITION, ELECTRON_SIZE);
  await ensureSentinelFrontmost();
}

function focusStateAt(timestampMs) {
  let state = focusEvents[0];
  for (const event of focusEvents) {
    if (event.timestampMs > timestampMs) break;
    state = event;
  }
  return state;
}

function analyzeFocus(startMs, actionEndMs, measurementEndMs, targetPid) {
  const startState = focusStateAt(startMs);
  const transitions = focusEvents.filter(
    (event) => event.timestampMs > startMs && event.timestampMs <= measurementEndMs
  );
  const points = [
    { timestampMs: startMs, pid: startState?.pid, name: startState?.name },
    ...transitions,
    { timestampMs: measurementEndMs, pid: undefined, name: undefined },
  ];

  let interruptedMs = 0;
  let targetForegroundMs = 0;
  let interruptionCount = 0;
  let longestInterruptionMs = 0;
  let currentInterruptionMs = 0;
  let previousWasSentinel = points[0].pid === sentinelPid;

  for (let index = 0; index < points.length - 1; index += 1) {
    const point = points[index];
    const next = points[index + 1];
    const duration = Math.max(0, next.timestampMs - point.timestampMs);
    const interrupted = point.pid !== sentinelPid;
    if (interrupted) {
      interruptedMs += duration;
      currentInterruptionMs += duration;
      if (point.pid === targetPid) targetForegroundMs += duration;
      if (previousWasSentinel) interruptionCount += 1;
    } else {
      longestInterruptionMs = Math.max(longestInterruptionMs, currentInterruptionMs);
      currentInterruptionMs = 0;
    }
    previousWasSentinel = !interrupted;
  }
  longestInterruptionMs = Math.max(longestInterruptionMs, currentInterruptionMs);

  const atReturn = focusStateAt(actionEndMs);
  const atMeasurementEnd = focusStateAt(measurementEndMs);
  return {
    interruptionCount,
    interruptedMs,
    targetForegroundMs,
    longestInterruptionMs,
    frontmostAtReturn: atReturn?.pid,
    frontmostAfterGrace: atMeasurementEnd?.pid,
    leftForegroundAtReturn: atReturn?.pid !== sentinelPid,
    leftForegroundAfterGrace: atMeasurementEnd?.pid !== sentinelPid,
  };
}

function formatMeasurement(metric) {
  if (metric.interruptionCount === 0 && !metric.leftForegroundAfterGrace) {
    return "no foreground interruption";
  }
  const count = `${metric.interruptionCount} interruption${metric.interruptionCount === 1 ? "" : "s"}`;
  const duration = `${metric.interruptedMs}ms displaced`;
  const tail = metric.leftForegroundAfterGrace
    ? ", target remained foreground (restored by demo)"
    : ", foreground restored";
  return `${count}, ${duration}${tail}`;
}

async function measuredAction(name, targetPid, action) {
  await ensureSentinelFrontmost();
  const stepStarted = Date.now();
  console.log(`  • ${name}`);
  try {
    const startMs = Date.now();
    const value = await action();
    const actionEndMs = Date.now();
    await sleep(measurementGraceMs);
    const measurementEndMs = Date.now();
    const metric = {
      name,
      targetPid,
      actionDurationMs: actionEndMs - startMs,
      ...analyzeFocus(startMs, actionEndMs, measurementEndMs, targetPid),
    };
    measurements.push(metric);
    console.log(`    ${formatMeasurement(metric)}`);
    if (metric.leftForegroundAfterGrace) await ensureSentinelFrontmost();
    const result = {
      name,
      status: "pass",
      durationMs: Date.now() - stepStarted,
      value,
    };
    outcomes.push(result);
    if (actionHoldMs > 0) await sleep(actionHoldMs);
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
    try {
      await ensureSentinelFrontmost();
    } catch {
      // Preserve the original tool failure.
    }
    return result;
  }
}

async function runBackgroundDemo() {
  await measuredAction("Connect native app", nativePid, async () => {
    const connection = await pollTool(
      "connect_app",
      { pid: nativePid },
      isConnectAppSuccess
    );
    nativePid = pidFromConnect(connection);
  });

  await measuredAction("Connect Electron app", electronPid, async () => {
    const connection = await pollTool(
      "connect_app",
      { pid: electronPid, readyTimeoutMs: 8_000 },
      isConnectAppSuccess,
      20_000
    );
    electronPid = pidFromConnect(connection);
  });

  await measuredAction("Fill native name", nativePid, () =>
    callTool("fill", {
      app: nativePid,
      query: q("text_field", "name-input"),
      value: "Lady Macbeth",
    })
  );

  await measuredAction("Fill native email", nativePid, () =>
    callTool("fill", {
      app: nativePid,
      query: q("text_field", "email-input"),
      value: "lady@dunsinane.example",
    })
  );

  await measuredAction("Click native checkbox", nativePid, () =>
    callTool("click", {
      app: nativePid,
      query: q("checkbox", "notifications-checkbox"),
    })
  );

  await measuredAction("Click native Submit", nativePid, () =>
    callTool("click", {
      app: nativePid,
      query: q("button", "submit-btn"),
    })
  );

  await measuredAction("Fill Electron name", electronPid, () =>
    callTool("fill", {
      app: electronPid,
      query: [{ role: "text_field", title: "Name:" }],
      value: "Electron Demo",
    })
  );

  await measuredAction("Click Electron Submit", electronPid, () =>
    callTool("click", {
      app: electronPid,
      query: [{ role: "button", title: "Submit" }],
    })
  );

  await measuredAction("Screenshot native window", nativePid, async () => {
    const saved = jsonOf(await callTool("screenshot", { app: nativePid }));
    assert(saved.path && saved.width > 0 && saved.height > 0, "Screenshot metadata was incomplete");
    artifacts.push(saved.path);
  });
}

async function cleanup() {
  if (cleanupStarted) return;
  cleanupStarted = true;
  const cleanupStartedAt = Date.now();
  const cleanupErrors = [];

  try {
    if (Number.isFinite(sentinelPid) && mcpConnected) await ensureSentinelFrontmost();
  } catch (error) {
    cleanupErrors.push(`could not restore foreground app: ${error instanceof Error ? error.message : String(error)}`);
  }

  await stopFocusWatcher();

  if (mcpConnected) {
    const fixturePids = ownedFixturePids();

    if (fixturePids.length > 0) {
      try {
        await callTool("run_applescript", {
          source: `do shell script "/bin/kill -TERM ${fixturePids.join(" ")} 2>/dev/null || true"`,
        });
      } catch (error) {
        cleanupErrors.push(`could not terminate fixtures: ${error instanceof Error ? error.message : String(error)}`);
      }

      const deadline = Date.now() + 3_000;
      let remaining = new Set(fixturePids);
      while (remaining.size > 0 && Date.now() < deadline) {
        try {
          const apps = textOf(await callTool("list_apps"));
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
          });
        } catch (error) {
          cleanupErrors.push(`could not force-close fixtures: ${error instanceof Error ? error.message : String(error)}`);
        }
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
}

async function shutdownFromSignal(signal, exitCode) {
  if (signalShutdownStarted) return;
  signalShutdownStarted = true;
  console.error(`\n${signal} received; restoring foreground app and closing fixtures…`);
  await cleanup();
  process.exit(exitCode);
}

process.once("SIGINT", () => { void shutdownFromSignal("SIGINT", 130); });
process.once("SIGTERM", () => { void shutdownFromSignal("SIGTERM", 143); });

function printSummary() {
  const totalMs = Date.now() - startedAt;
  const counts = { pass: 0, fail: 0 };
  console.log("\n━━ Background interruption summary ━━");
  console.log(`Foreground sentinel: ${sentinelName} (pid ${sentinelPid})`);
  for (const result of outcomes) {
    counts[result.status] = (counts[result.status] ?? 0) + 1;
    const mark = result.status === "pass" ? "✓" : "✗";
    const detail = result.detail ? ` — ${result.detail}` : "";
    console.log(`${mark} ${result.name} [${result.status}, ${result.durationMs}ms]${detail}`);
  }

  const interruptedActions = measurements.filter(
    (metric) => metric.interruptionCount > 0 || metric.leftForegroundAfterGrace
  );
  const totalInterruptions = measurements.reduce(
    (sum, metric) => sum + metric.interruptionCount,
    0
  );
  const totalInterruptedMs = measurements.reduce(
    (sum, metric) => sum + metric.interruptedMs,
    0
  );
  const leftForeground = measurements.filter((metric) => metric.leftForegroundAfterGrace);

  console.log("\nFocus impact:");
  console.log(`  ${interruptedActions.length}/${measurements.length} actions interrupted ${sentinelName}`);
  console.log(`  ${totalInterruptions} focus switches, ${totalInterruptedMs}ms total displacement`);
  console.log(`  ${leftForeground.length} actions left a demo app foreground after returning`);
  for (const metric of interruptedActions) {
    console.log(`  • ${metric.name}: ${formatMeasurement(metric)}`);
  }

  if (artifacts.length > 0) {
    console.log("\nScreenshot artifacts:");
    for (const path of artifacts) console.log(`  ${path}`);
  }
  console.log(`\n${counts.pass ?? 0} passed, ${counts.fail ?? 0} failed in ${(totalMs / 1000).toFixed(1)}s`);
  return counts.fail ?? 0;
}

async function main() {
  prepare();
  await connectMcp();
  await startFocusWatcher();
  await captureInitialState();

  console.log(`Keeping ${sentinelName} (pid ${sentinelPid}) in front during every measured action.`);
  await stageApps();
  await runBackgroundDemo();
}

let fatalError;
try {
  await main();
} catch (error) {
  fatalError = error;
  outcomes.push({
    name: "Background demo runner",
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
