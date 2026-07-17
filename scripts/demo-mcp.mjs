#!/usr/bin/env node

// Recording-friendly integration demo. Node subprocesses are permitted only
// during bootstrap. Once the MCP transport is connected, every Macbeth/app
// operation goes through MCP protocol calls or MCP tools.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const NATIVE_BUNDLE = join(ROOT, "test-harness/.build/MacbethTestApp.app");
const ELECTRON_APP = join(ROOT, "electron-testapp");
const ELECTRON_BUNDLE = join(ELECTRON_APP, "node_modules/electron/dist/Electron.app");
const MCP_ENTRY = join(ROOT, "client/bin/macbeth.mjs");
const BUILD_TMP = join(ROOT, ".tmp");
const SWIFT_MODULE_CACHE = join(BUILD_TMP, "swift-module-cache");
const DEMO_RUNTIME = join(BUILD_TMP, "mcp-demo-runtime");

const args = parseArgs(process.argv.slice(2));
const delayMs = args.fast ? 0 : args.delayMs ?? 750;
const sectionDelayMs = args.fast ? 0 : Math.max(1200, delayMs * 2);

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
const createdFixturePids = new Set();

const APP_NATIVE = "Macbeth TestApp";
const q = (role, identifier, extra = {}) => [{ role, identifier, ...extra }];
const statusQuery = q("text", "status-label");

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
  console.log(`Usage: npm run demo:mcp -- [options]

Options:
  --delay-ms <ms>  Pause between MCP operations (default: 750)
  --fast           Disable presentation pauses
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

async function callTool(name, toolArgs = {}, options = {}) {
  const prefix = options.quiet ? "" : `    MCP → ${name}`;
  if (prefix) console.log(prefix);
  const result = await client.callTool({ name, arguments: toolArgs });
  const text = textOf(result);
  if (result.isError) throw new Error(text || `${name} returned an MCP error`);
  if (!options.quiet && text) {
    const firstLine = text.split("\n")[0];
    console.log(`          ${firstLine.slice(0, 120)}${firstLine.length > 120 ? "…" : ""}`);
  }
  if (!options.noDelay && delayMs > 0) await sleep(delayMs);
  return result;
}

async function step(name, action, options = {}) {
  if (options.dependsOn?.some((dependency) => dependency?.status !== "pass")) {
    const result = { name, status: "skip", durationMs: 0, detail: "dependency failed" };
    outcomes.push(result);
    console.log(`  ↷ ${name} (skipped)`);
    return result;
  }

  const stepStarted = Date.now();
  console.log(`  • ${name}`);
  try {
    const value = await action();
    const result = { name, status: "pass", durationMs: Date.now() - stepStarted, value };
    outcomes.push(result);
    console.log(`  ✓ ${name} (${result.durationMs}ms)`);
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

async function section(title) {
  if (sectionDelayMs > 0) await sleep(sectionDelayMs);
  console.log(`\n━━ ${title} ━━`);
}

async function pollTool(name, toolArgs, predicate, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  let lastText = "";
  while (Date.now() < deadline) {
    try {
      const result = await callTool(name, toolArgs, { quiet: true, noDelay: true });
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

function pidsForListedName(text, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return [...text.matchAll(new RegExp(`^${escaped} \\(pid: (\\d+),`, "gm"))]
    .map((match) => Number(match[1]));
}

function rememberCreatedFixtures(appListText) {
  for (const pid of pidsForListedName(appListText, APP_NATIVE)) {
    if (!baselineNativePids.has(pid)) createdFixturePids.add(pid);
  }
  for (const pid of pidsForListedName(appListText, "Electron")) {
    if (!baselineElectronPids.has(pid)) createdFixturePids.add(pid);
  }
}

async function captureInitialState() {
  const apps = textOf(await callTool("list_apps", {}, { quiet: true, noDelay: true }));
  for (const pid of pidsForListedName(apps, APP_NATIVE)) baselineNativePids.add(pid);
  for (const pid of pidsForListedName(apps, "Electron")) baselineElectronPids.add(pid);

  const frontmost = textOf(await callTool("run_applescript", {
    interaction: "read_only",
    source: `tell application "System Events"
      return unix id of first application process whose frontmost is true
    end tell`,
  }, { quiet: true, noDelay: true }));
  const parsedPid = Number(frontmost.trim());
  if (Number.isFinite(parsedPid)) originalFrontmostPid = parsedPid;
}

async function concurrentWait(waitArgs, trigger) {
  const waitPromise = callTool("wait_for", waitArgs, { noDelay: true });
  await sleep(300);
  await trigger();
  return waitPromise;
}

async function prepare() {
  console.log("Preparing daemon, client, and demo apps…");
  mkdirSync(SWIFT_MODULE_CACHE, { recursive: true });
  mkdirSync(DEMO_RUNTIME, { recursive: true });
  if (!existsSync(join(ROOT, "node_modules/@modelcontextprotocol/sdk/package.json"))) {
    runBootstrap("npm", ["install"]);
  }
  if (!existsSync(ELECTRON_BUNDLE)) {
    runBootstrap("npm", ["ci", "--prefix", "electron-testapp"]);
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
  client = new Client({ name: "macbeth-feature-demo", version: "1.0.0" });
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

async function launchApps() {
  await callTool("run_applescript", {
    source: `do shell script "/usr/bin/open -g -n " & quoted form of "${NATIVE_BUNDLE}"`,
  });
  await pollTool("list_apps", {}, (text) => {
    rememberCreatedFixtures(text);
    const launchedPid = pidsForListedName(text, APP_NATIVE)
      .find((pid) => !baselineNativePids.has(pid));
    if (!launchedPid) return false;
    nativePid = launchedPid;
    return true;
  });

  await callTool("run_applescript", {
    source: `do shell script "/usr/bin/open -g -n -a " & quoted form of "${ELECTRON_BUNDLE}" & " --args " & quoted form of "${ELECTRON_APP}"`,
  });
  await pollTool("list_apps", {}, (text) => {
    rememberCreatedFixtures(text);
    const launchedPid = pidsForListedName(text, "Electron")
      .find((pid) => !baselineElectronPids.has(pid));
    if (!launchedPid) return false;
    electronPid = launchedPid;
    return true;
  });
  // Position both windows before the first connect_app. Connecting emits the
  // target outline, so doing it earlier would leave a stale outline at the
  // fixture's pre-layout frame.
  await callTool("run_applescript", {
    source: `tell application "System Events"
      tell (first application process whose unix id is ${nativePid})
        set position of window 1 to {40, 70}
        set frontmost to true
      end tell
      tell (first application process whose unix id is ${electronPid})
        set position of window 1 to {680, 70}
      end tell
    end tell`,
  });

  const electronConnection = await pollTool(
    "connect_app",
    { pid: electronPid, readyTimeoutMs: 8_000 },
    (text) => text.includes("Connected to"),
    20_000
  );
  electronPid = pidFromConnect(electronConnection);
  const nativeConnection = await pollTool(
    "connect_app",
    { pid: nativePid },
    (text) => text.includes("Connected to")
  );
  nativePid = pidFromConnect(nativeConnection);
}

async function runDemo() {
  await section("Native actions and input strategies");
  await step("Auto and forced AX fills plus slider fill", async () => {
    await callTool("fill", { app: nativePid, query: q("text_field", "name-input"), value: "Lady Macbeth" });
    await callTool("fill", {
      app: nativePid,
      query: q("text_field", "email-input"),
      value: "lady@dunsinane.example",
      strategy: "ax",
    });
    await callTool("fill", { app: nativePid, query: q("slider", "volume-slider"), value: "72" });
    const slider = jsonOf(await callTool("get_element", {
      app: nativePid,
      query: q("slider", "volume-slider"),
    }, { quiet: true, noDelay: true }));
    assert(Number(slider.value) === 72, `Slider value is ${slider.value}, expected 72`);
  });

  await step("Forced AX, auto, and handle-targeted clicks", async () => {
    await callTool("click", {
      app: nativePid,
      query: q("checkbox", "notifications-checkbox"),
      strategy: "ax",
    });
    await callTool("click", { app: nativePid, query: q("button", "advance-progress-btn") });
    const submit = jsonOf(await callTool("get_element", {
      app: nativePid,
      query: q("button", "submit-btn"),
    }, { quiet: true, noDelay: true }));
    await callTool("click", { app: nativePid, handleId: submit.handleId });
    const status = jsonOf(await callTool("get_element", {
      app: nativePid,
      query: statusQuery,
    }, { quiet: true, noDelay: true }));
    assert(String(status.value).includes("Submitted"), `Unexpected status: ${status.value}`);
  });

  await step("Single and batched keyboard shortcuts", async () => {
    await callTool("click", { app: nativePid, query: q("button", "advance-progress-btn") });
    await callTool("press_key", { app: nativePid, key: "r", modifiers: ["cmd", "shift"] });
    await callTool("wait_for", {
      app: nativePid,
      query: statusQuery,
      timeout: 3,
      condition: { kind: "value_equals", value: "Status: Demo reset from menu" },
    }, { quiet: true, noDelay: true });
    await callTool("click", { app: nativePid, query: q("checkbox", "notifications-checkbox") });
    await callTool("press_keys", {
      app: nativePid,
      keys: [
        { key: "r", modifiers: ["cmd", "shift"], delayMs: 100 },
        { key: "tab", delayMs: 100 },
      ],
    });
    await callTool("wait_for", {
      app: nativePid,
      query: statusQuery,
      timeout: 3,
      condition: { kind: "value_equals", value: "Status: Demo reset from menu" },
    }, { quiet: true, noDelay: true });
  });

  await section("Wait conditions, dialogs, and menus");
  await step("Menu discovery and deterministic menu selection", async () => {
    const menu = textOf(await callTool(
      "list_menu_bar", { app: APP_NATIVE }, { quiet: true, noDelay: true }
    ));
    assert(menu.includes("Demo"), "Demo menu was not discovered");
    assert(menu.includes("Reset Demo"), "Reset Demo item was not discovered");
    await callTool("select_menu_item", { app: APP_NATIVE, menuPath: ["Demo", "Reset Demo"] });
    await callTool("wait_for", {
      app: nativePid,
      query: statusQuery,
      timeout: 3,
      condition: { kind: "value_equals", value: "Status: Demo reset from menu" },
    }, { quiet: true, noDelay: true });
  });

  await step("wait_for exists discovers a modal", async () => {
    await concurrentWait(
      {
        app: nativePid,
        query: [{ role: "window", title: "Modal Dialog" }],
        timeout: 5,
        condition: { kind: "exists" },
      },
      () => callTool("click", { app: nativePid, query: q("button", "modal-btn") }, { noDelay: true })
    );
    await callTool("fill", { app: nativePid, query: q("text_field", "modal-text-input"), value: "modal probe" });
    await callTool("click", { app: nativePid, query: q("button", "modal-close-btn") });
  });

  await step("wait_for value_equals and value_changes", async () => {
    await callTool("fill", { app: nativePid, query: q("text_field", "name-input"), value: "Wait Target" });
    await callTool("wait_for", {
      app: nativePid,
      query: q("text_field", "name-input"),
      timeout: 3,
      condition: { kind: "value_equals", value: "Wait Target" },
    }, { quiet: true, noDelay: true });
    await concurrentWait(
      {
        app: nativePid,
        query: statusQuery,
        timeout: 5,
        condition: { kind: "value_changes" },
      },
      () => callTool("click", { app: nativePid, query: q("button", "advance-progress-btn") }, { noDelay: true })
    );
  });

  await step("wait_for enabled observes a real transition", async () => {
    await concurrentWait(
      {
        app: nativePid,
        query: q("button", "gated-action-btn"),
        timeout: 5,
        condition: { kind: "enabled" },
      },
      () => callTool("click", { app: nativePid, query: q("button", "enable-action-btn") }, { noDelay: true })
    );
    await callTool("click", { app: nativePid, query: q("button", "gated-action-btn") });
  });

  await step("Native alert can be inspected and dismissed", async () => {
    await concurrentWait(
      {
        app: nativePid,
        query: q("button", "alert-delete"),
        timeout: 5,
        condition: { kind: "exists" },
      },
      () => callTool("click", { app: nativePid, query: q("button", "alert-btn") }, { noDelay: true })
    );
    await callTool("click", { app: nativePid, query: q("button", "alert-delete") });
    await callTool("wait_for", {
      app: nativePid,
      query: statusQuery,
      timeout: 3,
      condition: { kind: "value_equals", value: "Status: Alert – Delete clicked" },
    }, { quiet: true, noDelay: true });
  });

  await section("Electron web content");
  await step("Electron auto and keyboard fill deliver input events", async () => {
    await callTool("fill", {
      app: electronPid,
      query: [{ role: "text_field", title: "Name:" }],
      value: "Electron Auto",
    });
    let tree = textOf(await callTool(
      "query_tree", { app: electronPid, maxDepth: 12 }, { quiet: true, noDelay: true }
    ));
    assert(tree.includes("Mirror: Electron Auto"), "Auto fill did not update the Electron mirror");
    await callTool("fill", {
      app: electronPid,
      query: [{ role: "text_field", title: "Name:" }],
      value: "Electron Keyboard",
      strategy: "keyboard",
    });
    tree = textOf(await callTool(
      "query_tree", { app: electronPid, maxDepth: 12 }, { quiet: true, noDelay: true }
    ));
    assert(tree.includes("Mirror: Electron Keyboard"), "Keyboard fill did not update the Electron mirror");
  });

  await step("Forced mouse click with idle protection", async () => {
    await callTool("fill", {
      app: electronPid,
      query: [{ role: "text_field", title: "Email:" }],
      value: "electron@example.test",
    });
    await callTool("click", {
      app: electronPid,
      query: [{ role: "button", title: "Submit" }],
      strategy: "mouse",
      waitForIdleMs: 50,
    });
    const tree = textOf(await callTool(
      "query_tree", { app: electronPid, maxDepth: 12 }, { quiet: true, noDelay: true }
    ));
    assert(tree.includes("Submitted"), "Mouse click did not submit the Electron form");
  });

  await section("Capture and OCR");
  await step("Full native screenshot", async () => {
    const saved = jsonOf(await callTool("screenshot", { app: nativePid }));
    assert(saved.path && saved.width > 0 && saved.height > 0, "Screenshot metadata was incomplete");
    artifacts.push(saved.path);
  });

  await step("Cropped Electron screenshot", async () => {
    const saved = jsonOf(await callTool("screenshot", {
      app: electronPid,
      region: { x: 0, y: 0, width: 500, height: 320 },
    }));
    assert(saved.path && saved.width > 0 && saved.height > 0, "Cropped screenshot metadata was incomplete");
    artifacts.push(saved.path);
  });

  await step("OCR an app window", async () => {
    const text = textOf(await callTool("extract_text", { app: nativePid }));
    assert(
      text.includes("Macbeth") || text.includes("Text Inputs") || text.includes("Sliders & Steppers"),
      `Expected fixture text in OCR output: ${text.slice(0, 100)}`,
    );
  });

}

async function cleanup() {
  if (cleanupStarted) return;
  cleanupStarted = true;
  const cleanupStartedAt = Date.now();
  const cleanupErrors = [];

  if (mcpConnected) {
    try {
      const apps = textOf(await callTool("list_apps", {}, { quiet: true, noDelay: true }));
      rememberCreatedFixtures(apps);
    } catch (error) {
      cleanupErrors.push(`could not discover fixture processes: ${error instanceof Error ? error.message : String(error)}`);
    }

    for (const pid of [nativePid, electronPid]) {
      if (Number.isFinite(pid)) createdFixturePids.add(pid);
    }

    if (createdFixturePids.size > 0) {
      try {
        await callTool("run_applescript", {
          source: `do shell script "/bin/kill -TERM ${[...createdFixturePids].join(" ")} 2>/dev/null || true"`,
        }, { quiet: true, noDelay: true });
      } catch (error) {
        cleanupErrors.push(`could not terminate fixtures: ${error instanceof Error ? error.message : String(error)}`);
      }

      const deadline = Date.now() + 3_000;
      let remaining = new Set(createdFixturePids);
      while (remaining.size > 0 && Date.now() < deadline) {
        try {
          const apps = textOf(await callTool("list_apps", {}, { quiet: true, noDelay: true }));
          const running = new Set([
            ...pidsForListedName(apps, APP_NATIVE),
            ...pidsForListedName(apps, "Electron"),
          ]);
          remaining = new Set([...remaining].filter((pid) => running.has(pid)));
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
          }, { quiet: true, noDelay: true });
        } catch (error) {
          cleanupErrors.push(`could not force-close fixtures: ${error instanceof Error ? error.message : String(error)}`);
        }

        try {
          await sleep(100);
          const apps = textOf(await callTool("list_apps", {}, { quiet: true, noDelay: true }));
          const stillRunning = new Set([
            ...pidsForListedName(apps, APP_NATIVE),
            ...pidsForListedName(apps, "Electron"),
          ]);
          remaining = new Set([...remaining].filter((pid) => stillRunning.has(pid)));
          if (remaining.size > 0) {
            cleanupErrors.push(`fixture PIDs still running: ${[...remaining].join(", ")}`);
          }
        } catch (error) {
          cleanupErrors.push(`could not verify forced fixture exit: ${error instanceof Error ? error.message : String(error)}`);
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
        }, { quiet: true, noDelay: true });
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
  console.log("\n━━ Demo summary ━━");
  for (const result of outcomes) {
    counts[result.status] += 1;
    const mark = result.status === "pass" ? "✓" : result.status === "fail" ? "✗" : "↷";
    const detail = result.detail ? ` — ${result.detail}` : "";
    console.log(`${mark} ${result.name} [${result.status}, ${result.durationMs}ms]${detail}`);
  }
  if (artifacts.length > 0) {
    console.log("\nScreenshot artifacts:");
    for (const path of artifacts) console.log(`  ${path}`);
  }
  console.log(`\n${counts.pass} passed, ${counts.fail} failed, ${counts.skip} skipped in ${(totalMs / 1000).toFixed(1)}s`);
  return counts.fail;
}

async function main() {
  await prepare();
  await connectMcp();
  await captureInitialState();

  if (!args.fast) {
    console.log("\nRecording starts in…");
    for (const count of [3, 2, 1]) {
      console.log(`  ${count}`);
      await sleep(1000);
    }
  }

  const launch = await step("Launch native and Electron fixtures through MCP", launchApps);
  if (launch.status === "pass") await runDemo();
  else outcomes.push({ name: "Feature presentation", status: "skip", durationMs: 0, detail: "apps did not launch" });
}

let fatalError;
try {
  await main();
} catch (error) {
  fatalError = error;
  outcomes.push({
    name: "Demo runner",
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
