/**
 * MCP demo foregrounding + outline regression suite.
 *
 * Reproduces each public MCP demo step from `scripts/demo-mcp.mjs` with an
 * explicit background → action → checks. Invariants under test:
 * 1. After the MCP tool returns, the fixture app must not be frontmost.
 * 2. While the fixture is backgrounded, macbeth-glow must not draw a target
 *    outline (outline is only for the system-wide focused frontmost window).
 *    Screenshot may still show a capture scan/snap overlay; that is intentional.
 *
 * Some actions currently steal focus (keyboard synthesis, press_key, Electron
 * keyboard fill). Those cases are expected to fail until the daemon stops
 * activating the target for that path. Do not invert or skip them.
 *
 * Opt-in (requires Accessibility + Screen Recording):
 *   MACBETH_GUI_FOREGROUND_TESTS=1 npm run test:gui:foreground
 */

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

const rootDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const nativeBundle = join(rootDir, "test-harness/.build/MacbethTestApp.app");
const electronApp = join(rootDir, "electron-testapp");
const electronBundle = join(electronApp, "node_modules/electron/dist/Electron.app");
const mcpEntry = join(rootDir, "client/bin/macbeth.mjs");
const glowOutlineSource = join(rootDir, "scripts/list-glow-outlines.swift");
const glowOutlineBinary = join(rootDir, ".tmp/list-glow-outlines");

const enabled =
  process.platform === "darwin" && process.env.MACBETH_GUI_FOREGROUND_TESTS === "1";
const suite = enabled ? describe : describe.skip;

const APP_NATIVE = "Macbeth TestApp";
const sleep = (ms: number) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
const q = (role: string, identifier: string, extra: Record<string, unknown> = {}) => [
  { role, identifier, ...extra },
];
const statusQuery = q("text", "status-label");

type McpClient = {
  callTool: (params: { name: string; arguments?: Record<string, unknown> }) => Promise<{
    content?: Array<{ type: string; text?: string }>;
    isError?: boolean;
  }>;
  close: () => Promise<void>;
};

type McpTransport = { close: () => Promise<void> };

type GlowOutlineSnapshot = {
  /** Navigation outline windows (frontmost-only chrome). */
  outlines: number;
  /** Capture scan/snap windows (allowed during background screenshots). */
  captures: number;
  windows: Array<{
    owner: string;
    kind?: string;
    pid: number;
    layer: number;
    width: number;
    height: number;
    x: number;
    y: number;
  }>;
};

suite("MCP demo steps must not leave the fixture frontmost", () => {
  let client: McpClient;
  let transport: McpTransport;
  let nativePid: number;
  let electronPid: number;
  let sentinelPid: number;
  const createdPids = new Set<number>();

  function textOf(result: { content?: Array<{ type: string; text?: string }> }): string {
    return (result.content ?? [])
      .filter((item) => item.type === "text")
      .map((item) => item.text ?? "")
      .join("\n");
  }

  function jsonOf(result: { content?: Array<{ type: string; text?: string }> }): Record<string, unknown> {
    const text = textOf(result);
    try {
      return JSON.parse(text) as Record<string, unknown>;
    } catch {
      throw new Error(`Expected JSON tool output, received: ${text.slice(0, 300)}`);
    }
  }

  async function callTool(
    name: string,
    args: Record<string, unknown> = {}
  ): Promise<{ content?: Array<{ type: string; text?: string }>; isError?: boolean }> {
    const result = await client.callTool({ name, arguments: args });
    if (result.isError) {
      throw new Error(textOf(result) || `${name} returned an MCP error`);
    }
    return result;
  }

  async function getFrontmostPid(): Promise<number> {
    const result = await callTool("run_applescript", {
      interaction: "read_only",
      source: `tell application "System Events"
        return unix id of first application process whose frontmost is true
      end tell`,
    });
    const pid = Number(textOf(result).trim());
    if (!Number.isFinite(pid)) {
      throw new Error(`Could not parse frontmost pid from: ${textOf(result)}`);
    }
    return pid;
  }

  async function setFrontmost(pid: number): Promise<void> {
    await callTool("run_applescript", {
      source: `tell application "System Events"
        set frontmost of first application process whose unix id is ${pid} to true
        return "ok"
      end tell`,
    });
  }

  async function sendToBackground(targetPid: number): Promise<void> {
    await setFrontmost(sentinelPid);
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      const front = await getFrontmostPid();
      if (front !== targetPid && front === sentinelPid) return;
      await setFrontmost(sentinelPid);
      await sleep(50);
    }
    const front = await getFrontmostPid();
    throw new Error(
      `Could not background pid ${targetPid}; frontmost is ${front} (sentinel ${sentinelPid})`
    );
  }

  function ensureGlowOutlineDetector(): void {
    expect(existsSync(glowOutlineSource)).toBe(true);
    const sourceMtime = statSync(glowOutlineSource).mtimeMs;
    const binaryFresh =
      existsSync(glowOutlineBinary) && statSync(glowOutlineBinary).mtimeMs >= sourceMtime;
    if (binaryFresh) return;
    mkdirSync(dirname(glowOutlineBinary), { recursive: true });
    execFileSync("swiftc", ["-O", glowOutlineSource, "-o", glowOutlineBinary], {
      stdio: "inherit",
    });
  }

  function listGlowOutlines(): GlowOutlineSnapshot {
    ensureGlowOutlineDetector();
    const raw = execFileSync(glowOutlineBinary, { encoding: "utf8" }).trim();
    try {
      return JSON.parse(raw) as GlowOutlineSnapshot;
    } catch {
      throw new Error(`Could not parse glow outline detector output: ${raw.slice(0, 200)}`);
    }
  }

  /**
   * Require a sustained clear (not a single false-negative sample). Glow hold
   * is 400ms + fade; 700ms of continuous zeros is enough to outlast a flaky read.
   */
  async function waitForNoGlowOutline(timeoutMs = 5_000, stableMs = 700): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    let clearSince: number | null = null;
    let last = listGlowOutlines();
    while (Date.now() < deadline) {
      last = listGlowOutlines();
      if (last.outlines === 0) {
        if (clearSince == null) clearSince = Date.now();
        if (Date.now() - clearSince >= stableMs) return;
      } else {
        clearSince = null;
      }
      await sleep(40);
    }
    throw new Error(
      `Timed out waiting for macbeth-glow outline to clear (still ${last.outlines}): ${JSON.stringify(last.windows)}`
    );
  }

  /**
   * Put the target in the background, run one MCP action, then assert:
   * - the fixture is still not frontmost when the tool returns
   * - no macbeth-glow target outline appeared while it was backgrounded
   */
  async function expectStaysBackgrounded(
    targetPid: number,
    action: () => Promise<void>
  ): Promise<void> {
    await sendToBackground(targetPid);
    expect(await getFrontmostPid()).not.toBe(targetPid);
    // Drop any outline left over from connect / a prior case so this case only
    // fails on outlines produced by the action under test.
    await waitForNoGlowOutline();

    let peakOutlines = 0;
    let peakSnapshot: GlowOutlineSnapshot = { outlines: 0, captures: 0, windows: [] };
    let sampling = true;
    const sample = () => {
      const snapshot = listGlowOutlines();
      if (snapshot.outlines > peakOutlines) {
        peakOutlines = snapshot.outlines;
        peakSnapshot = snapshot;
      }
    };

    // Tight async poll (not setInterval): execFileSync is blocking, and we need
    // samples throughout the MCP call including brief re-arms from begin_activity.
    const poller = (async () => {
      while (sampling) {
        sample();
        await sleep(25);
      }
    })();

    try {
      await action();
      // Keep sampling through the post-action glow hold window.
      await sleep(200);
      sample();
    } finally {
      sampling = false;
      await poller;
    }

    expect(
      peakOutlines,
      `macbeth-glow outline appeared while fixture pid ${targetPid} was backgrounded: ${JSON.stringify(peakSnapshot.windows)}`
    ).toBe(0);

    const after = await getFrontmostPid();
    expect(
      after,
      `fixture pid ${targetPid} became frontmost after the MCP action (frontmost=${after}, sentinel=${sentinelPid})`
    ).not.toBe(targetPid);
  }

  function pidsForName(listText: string, name: string): number[] {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    // list_apps indents entries under a connectable / not-connectable heading.
    return [...listText.matchAll(new RegExp(`^\\s*${escaped} \\(pid: (\\d+),`, "gm"))].map((m) =>
      Number(m[1])
    );
  }

  async function pollListApps(
    predicate: (text: string) => number | undefined,
    timeoutMs = 15_000
  ): Promise<number> {
    const deadline = Date.now() + timeoutMs;
    let last = "";
    while (Date.now() < deadline) {
      last = textOf(await callTool("list_apps"));
      const pid = predicate(last);
      if (pid !== undefined) return pid;
      await sleep(200);
    }
    throw new Error(`Timed out waiting for app launch: ${last.slice(0, 200)}`);
  }

  async function resetNativeDemo(): Promise<void> {
    // Menu selection is itself under test later; here it is only fixture hygiene.
    // Temporarily allow focus changes from reset without failing the suite setup.
    try {
      await callTool("select_menu_item", {
        app: APP_NATIVE,
        menuPath: ["Demo", "Reset Demo"],
      });
    } catch {
      // Ignore if the menu path is unavailable mid-suite.
    }
    await sleep(100);
  }

  beforeAll(async () => {
    ensureGlowOutlineDetector();

    execFileSync(resolve(rootDir, "scripts/build-test-harness.sh"), {
      stdio: "inherit",
      cwd: rootDir,
    });
    expect(existsSync(nativeBundle)).toBe(true);

    if (!existsSync(electronBundle)) {
      execFileSync("npm", ["ci", "--prefix", "electron-testapp"], {
        stdio: "inherit",
        cwd: rootDir,
      });
    }
    expect(existsSync(electronBundle)).toBe(true);

    const [{ Client }, { StdioClientTransport }] = await Promise.all([
      import("@modelcontextprotocol/sdk/client/index.js"),
      import("@modelcontextprotocol/sdk/client/stdio.js"),
    ]);

    client = new Client({ name: "macbeth-foreground-suite", version: "1.0.0" }) as unknown as McpClient;
    transport = new StdioClientTransport({
      command: process.execPath,
      args: [mcpEntry],
      cwd: rootDir,
      stderr: "inherit",
    }) as unknown as McpTransport;
    await (client as unknown as { connect: (t: McpTransport) => Promise<void> }).connect(transport);

    sentinelPid = await getFrontmostPid();

    const baselineNative = new Set(pidsForName(textOf(await callTool("list_apps")), APP_NATIVE));
    const baselineElectron = new Set(pidsForName(textOf(await callTool("list_apps")), "Electron"));

    await callTool("run_applescript", {
      source: `do shell script "/usr/bin/open -g -n " & quoted form of "${nativeBundle}"`,
    });
    nativePid = await pollListApps((text) =>
      pidsForName(text, APP_NATIVE).find((pid) => !baselineNative.has(pid))
    );
    createdPids.add(nativePid);

    await callTool("run_applescript", {
      source: `do shell script "/usr/bin/open -g -n -a " & quoted form of "${electronBundle}" & " --args " & quoted form of "${electronApp}"`,
    });
    electronPid = await pollListApps((text) =>
      pidsForName(text, "Electron").find((pid) => !baselineElectron.has(pid))
    );
    createdPids.add(electronPid);

    async function positionWindow(pid: number, position: string): Promise<void> {
      const deadline = Date.now() + 15_000;
      let lastError = "";
      while (Date.now() < deadline) {
        try {
          const result = await callTool("run_applescript", {
            source: `tell application "System Events"
              tell (first application process whose unix id is ${pid})
                set position of window 1 to ${position}
              end tell
              return "ready"
            end tell`,
          });
          if (textOf(result).trim() === "ready") return;
        } catch (error) {
          lastError = error instanceof Error ? error.message : String(error);
        }
        await sleep(250);
      }
      throw new Error(`Could not position window for pid ${pid}: ${lastError}`);
    }

    // Process discovery can precede the first AX window. Poll positioning so a
    // transient missing window is treated as startup, not suite failure.
    await positionWindow(electronPid, "{680, 70}");
    await positionWindow(nativePid, "{40, 70}");

    await callTool("connect_app", { pid: electronPid, readyTimeoutMs: 8_000 });
    await callTool("connect_app", { pid: nativePid });

    // Leave both fixtures backgrounded relative to the pre-suite frontmost app.
    await sendToBackground(nativePid);
    await sendToBackground(electronPid);
  }, 90_000);

  afterAll(async () => {
    for (const pid of createdPids) {
      try {
        process.kill(pid, "SIGTERM");
      } catch {
        // already exited
      }
    }
    try {
      if (Number.isFinite(sentinelPid)) await setFrontmost(sentinelPid);
    } catch {
      // best effort
    }
    try {
      await client?.close();
    } catch {
      try {
        await transport?.close();
      } catch {
        // ignore
      }
    }
  }, 30_000);

  beforeEach(async () => {
    await resetNativeDemo();
    await sendToBackground(nativePid);
  });

  // ─── Demo section: Native actions and input strategies ───────────────────

  describe("Native actions and input strategies", () => {
    it("fill auto on name-input stays backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("fill", {
          app: nativePid,
          query: q("text_field", "name-input"),
          value: "Lady Macbeth",
        });
      });
    });

    it("fill strategy=ax on email-input stays backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("fill", {
          app: nativePid,
          query: q("text_field", "email-input"),
          value: "lady@dunsinane.example",
          strategy: "ax",
        });
      });
    });

    it("fill slider stays backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("fill", {
          app: nativePid,
          query: q("slider", "volume-slider"),
          value: "72",
        });
      });
    });

    it("get_element stays backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("get_element", {
          app: nativePid,
          query: q("slider", "volume-slider"),
        });
      });
    });

    it("click strategy=ax on checkbox stays backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("click", {
          app: nativePid,
          query: q("checkbox", "notifications-checkbox"),
          strategy: "ax",
        });
      });
    });

    it("click auto on advance-progress stays backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("click", {
          app: nativePid,
          query: q("button", "advance-progress-btn"),
        });
      });
    });

    it("click via handleId on submit stays backgrounded", async () => {
      const submit = jsonOf(
        await callTool("get_element", {
          app: nativePid,
          query: q("button", "submit-btn"),
        })
      );
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("click", {
          app: nativePid,
          handleId: submit.handleId as string,
        });
      });
    });

    it("press_key (cmd+shift+r) stays backgrounded", async () => {
      // Documented focus-stealer today; this assertion is intentionally strict.
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("press_key", {
          app: nativePid,
          key: "r",
          modifiers: ["cmd", "shift"],
        });
      });
    });

    it("press_keys stays backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("press_keys", {
          app: nativePid,
          keys: [
            { key: "r", modifiers: ["cmd", "shift"], delayMs: 50 },
            { key: "tab", delayMs: 50 },
          ],
        });
      });
    });

    it("fill strategy=keyboard stays backgrounded", async () => {
      // Keyboard synthesis activates the app so HID events land on the target.
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("fill", {
          app: nativePid,
          query: q("text_field", "name-input"),
          value: "Keyboard Path",
          strategy: "keyboard",
        });
      });
    });
  });

  // ─── Demo section: Wait conditions, dialogs, and menus ───────────────────

  describe("Wait conditions, dialogs, and menus", () => {
    it("list_menu_bar stays backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("list_menu_bar", { app: APP_NATIVE });
      });
    });

    it("select_menu_item Reset Demo stays backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("select_menu_item", {
          app: APP_NATIVE,
          menuPath: ["Demo", "Reset Demo"],
        });
      });
    });

    it("click that opens modal stays backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("click", {
          app: nativePid,
          query: q("button", "modal-btn"),
        });
      });
      // Close modal for isolation (may steal focus; not under assert here).
      try {
        await callTool("click", {
          app: nativePid,
          query: q("button", "modal-close-btn"),
          timeout: 3,
        });
      } catch {
        // modal may already be closed
      }
    });

    it("fill modal text field stays backgrounded", async () => {
      await callTool("click", {
        app: nativePid,
        query: q("button", "modal-btn"),
      });
      await callTool("wait_for", {
        app: nativePid,
        query: [{ role: "window", title: "Modal Dialog" }],
        timeout: 5,
        condition: { kind: "exists" },
      });

      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("fill", {
          app: nativePid,
          query: q("text_field", "modal-text-input"),
          value: "modal probe",
        });
      });

      await callTool("click", {
        app: nativePid,
        query: q("button", "modal-close-btn"),
      });
    });

    it("click modal close stays backgrounded", async () => {
      await callTool("click", {
        app: nativePid,
        query: q("button", "modal-btn"),
      });
      await callTool("wait_for", {
        app: nativePid,
        query: q("button", "modal-close-btn"),
        timeout: 5,
        condition: { kind: "exists" },
      });

      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("click", {
          app: nativePid,
          query: q("button", "modal-close-btn"),
        });
      });
    });

    it("wait_for value_equals stays backgrounded", async () => {
      await callTool("fill", {
        app: nativePid,
        query: q("text_field", "name-input"),
        value: "Wait Target",
      });
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("wait_for", {
          app: nativePid,
          query: q("text_field", "name-input"),
          timeout: 3,
          condition: { kind: "value_equals", value: "Wait Target" },
        });
      });
    });

    it("wait_for value_changes stays backgrounded", async () => {
      // Start wait first, then trigger from a concurrent task so wait itself is under test.
      const waitPromise = callTool("wait_for", {
        app: nativePid,
        query: statusQuery,
        timeout: 5,
        condition: { kind: "value_changes" },
      });
      await sleep(200);
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("click", {
          app: nativePid,
          query: q("button", "advance-progress-btn"),
        });
      });
      await waitPromise;
    });

    it("wait_for enabled stays backgrounded", async () => {
      const waitPromise = callTool("wait_for", {
        app: nativePid,
        query: q("button", "gated-action-btn"),
        timeout: 5,
        condition: { kind: "enabled" },
      });
      await sleep(200);
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("click", {
          app: nativePid,
          query: q("button", "enable-action-btn"),
        });
      });
      await waitPromise;
    });

    it("click gated-action stays backgrounded", async () => {
      await callTool("click", {
        app: nativePid,
        query: q("button", "enable-action-btn"),
      });
      await callTool("wait_for", {
        app: nativePid,
        query: q("button", "gated-action-btn"),
        timeout: 3,
        condition: { kind: "enabled" },
      });
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("click", {
          app: nativePid,
          query: q("button", "gated-action-btn"),
        });
      });
    });

    it("alert open + dismiss clicks stay backgrounded", async () => {
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("click", {
          app: nativePid,
          query: q("button", "alert-btn"),
        });
      });
      await callTool("wait_for", {
        app: nativePid,
        query: q("button", "alert-delete"),
        timeout: 5,
        condition: { kind: "exists" },
      });
      await expectStaysBackgrounded(nativePid, async () => {
        await callTool("click", {
          app: nativePid,
          query: q("button", "alert-delete"),
        });
      });
    });
  });

  // ─── Demo section: Electron web content ──────────────────────────────────

  describe("Electron web content", () => {
    beforeEach(async () => {
      await sendToBackground(electronPid);
    });

    it("Electron fill auto stays backgrounded", async () => {
      // Auto on Electron synthesizes keystrokes and currently activates.
      await expectStaysBackgrounded(electronPid, async () => {
        await callTool("fill", {
          app: electronPid,
          query: [{ role: "text_field", title: "Name:" }],
          value: "Electron Auto",
        });
      });
    });

    it("Electron fill strategy=keyboard stays backgrounded", async () => {
      await expectStaysBackgrounded(electronPid, async () => {
        await callTool("fill", {
          app: electronPid,
          query: [{ role: "text_field", title: "Name:" }],
          value: "Electron Keyboard",
          strategy: "keyboard",
        });
      });
    });

    it("Electron click strategy=mouse stays backgrounded after return", async () => {
      // Mouse path briefly activates then restores the previous frontmost app.
      await callTool("fill", {
        app: electronPid,
        query: [{ role: "text_field", title: "Email:" }],
        value: "electron@example.test",
      });
      await expectStaysBackgrounded(electronPid, async () => {
        await callTool("click", {
          app: electronPid,
          query: [{ role: "button", title: "Submit" }],
          strategy: "mouse",
          waitForIdleMs: 50,
        });
      });
    });

    it("Electron query_tree stays backgrounded", async () => {
      await expectStaysBackgrounded(electronPid, async () => {
        await callTool("query_tree", { app: electronPid, maxDepth: 12 });
      });
    });
  });

  // ─── Demo section: Capture and OCR ───────────────────────────────────────

  describe("Capture and OCR", () => {
    // Capture paths can be slow under load (ScreenCaptureKit + Vision); keep
    // generous per-test budgets so hangs surface as action errors, not vitest cuts.
    it(
      "screenshot native window stays backgrounded",
      async () => {
        await expectStaysBackgrounded(nativePid, async () => {
          await callTool("screenshot", { app: nativePid });
        });
      },
      60_000
    );

    it(
      "screenshot cropped Electron stays backgrounded",
      async () => {
        await expectStaysBackgrounded(electronPid, async () => {
          await callTool("screenshot", {
            app: electronPid,
            region: { x: 0, y: 0, width: 500, height: 320 },
          });
        });
      },
      60_000
    );

    it(
      "extract_text on native app stays backgrounded",
      async () => {
        await expectStaysBackgrounded(nativePid, async () => {
          await callTool("extract_text", { app: nativePid });
        });
      },
      60_000
    );
  });
});
