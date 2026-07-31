import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { execFile, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import { MacbethClient } from "./client.js";
import { isOperationTimeout, JsonRpcError, RPC_ERROR_NAMES } from "./errors.js";
import { runScreenshotTool } from "./mcp-screenshot.js";
import { saveScreenshotToTempFile } from "./screenshots.js";
import { resolveElementTarget } from "./mcp-target.js";
import { formatAppList } from "./app-target.js";
import { runWithActivity } from "./mcp-activity.js";
import { SCRIPT_TIMEOUT, scriptTimeoutFromSeconds } from "./timeouts.js";
import { readInstalledVersion } from "./update.js";
import type { KeyStroke } from "./types.js";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const INSTALL_DIR = resolve(MODULE_DIR, "..");
const SKILLS_DIR_CANDIDATES = [
  resolve(INSTALL_DIR, "skills"),
  resolve(INSTALL_DIR, "..", "skills"),
];
const SKILLS_DIR = SKILLS_DIR_CANDIDATES.find(existsSync) ?? SKILLS_DIR_CANDIDATES[0];

const client = new MacbethClient({ verbose: false });

const activityControl = {
  begin: () => client.beginActivity(),
  end: (token: string) => client.endActivity(token),
};

function withActivity<T>(operation: () => Promise<T>): Promise<T> {
  return runWithActivity(activityControl, operation, (error) => {
    const detail = error instanceof Error ? error.message : String(error);
    process.stderr.write(`[macbeth-mcp] Glow activity signal failed: ${detail}\n`);
  });
}

function formatError(prefix: string, err: unknown): string {
  if (err instanceof JsonRpcError) {
    const kind = RPC_ERROR_NAMES[err.code] ?? `error_${err.code}`;
    let msg = `${prefix} [${kind}]: ${err.message}`;
    if (err.data && typeof err.data === "object") {
      const d = err.data as Record<string, unknown>;
      if (d.osaErrorNumber != null) msg += ` (OSA error ${d.osaErrorNumber})`;
      if (d.phase != null) msg += ` (phase: ${d.phase})`;
      if (d.durationMs != null) msg += ` (duration: ${d.durationMs}ms)`;
    }
    return msg;
  }
  return `${prefix}: ${err instanceof Error ? err.message : String(err)}`;
}

/**
 * Format a script failure. A timeout is scoped to the call that hit it: say so
 * explicitly and point at the knob, so the agent raises `timeout` instead of
 * treating the whole server as broken and retrying blindly.
 */
function formatScriptError(err: unknown, timeoutSeconds: number): string {
  const base = formatError("Script failed", err);
  if (!isOperationTimeout(err)) return base;
  return `${base}\nThe script exceeded its ${timeoutSeconds}s budget and was stopped. `
    + "Only this call failed — the Macbeth server and every other tool are unaffected. "
    + `Re-run with a larger 'timeout' (up to ${SCRIPT_TIMEOUT.maxMs / 1_000}s) if the work `
    + "legitimately takes longer.";
}

const server = new McpServer(
  { name: "macbeth", version: readInstalledVersion(INSTALL_DIR) },
  { capabilities: { tools: {} } }
);

// --- Tools ---

const querySchema = z
  .array(
    z.object({
      role: z.string().optional().describe("AX role (e.g. 'button', 'window', 'text_field')"),
      title: z.string().optional().describe("Element title to match"),
      identifier: z.string().optional().describe("AX identifier to match"),
      titlePattern: z.string().optional().describe("Regex pattern to match against element title"),
      index: z.number().optional().describe("Which match to select when multiple elements match (0-based, default 0)"),
    })
  )
  .describe("Locator chain — each step recursively searches descendants of the previous match. No need to specify intermediate containers. Example: [{role:'window'}, {role:'button', title:'Submit'}] finds any button titled 'Submit' anywhere in the window.");

const keyStrokeSchema = z.object({
  key: z.string().optional().describe("Key name"),
  text: z.string().optional().describe("Literal text to type"),
  modifiers: z.array(z.string()).optional().describe('Modifier keys for `key` entries only (e.g. ["cmd", "shift"])'),
  delayMs: z.number().int().nonnegative().optional().describe("Optional delay after this item, in milliseconds"),
}).refine(
  (value) => (value.key ? 1 : 0) + (value.text ? 1 : 0) === 1,
  { message: 'Each item must include exactly one of "key" or "text"' }
).refine(
  (value) => value.text === undefined || value.modifiers === undefined,
  { message: '"modifiers" is only supported with "key"' }
);

// Keep PID targeting consistent with connect_app. This matters for unbundled
// native processes, which can be addressable by PID but not discoverable by name.
// App handles are accepted too, so connect_app's return value can be passed straight
// back in and no name is re-resolved.
const appTargetSchema = z
  .union([z.string(), z.number()])
  .describe('App name (fuzzy), PID, or an app handle returned by connect_app (e.g. "h_3")');

server.registerTool("list_apps", {
  description: "List running macOS apps, split into the ones that are currently reachable through the Accessibility API and the ones that are running but will fail to connect (launchers, helper processes, apps that never implement AX). Blocked entries carry the AX error code, what it means, and what to do instead.",
  annotations: { readOnlyHint: true },
}, async () => {
  const apps = await client.listApps();
  return { content: [{ type: "text", text: formatAppList(apps) }] };
});

server.registerTool("list_daemon_methods", {
  description: "List every JSON-RPC method registered by the daemon. Used to verify that daemon capabilities are exposed through MCP.",
  annotations: { readOnlyHint: true },
}, async () => {
  const methods = await client.listDaemonMethods();
  return { content: [{ type: "text", text: JSON.stringify({ methods }, null, 2) }] };
});

server.registerTool("begin_activity", {
  description:
    "Turn on the on-screen interaction indicator before you control the computer through some OTHER tool (a different MCP server, computer-use, a shell script) that Macbeth cannot see. Macbeth's own click/fill/press_key/run_applescript tools already show the indicator, so you do NOT need this for them. Returns a token; you MUST call end_activity with that token when the external work finishes (a crashed or disconnected client is cleaned up automatically after a timeout). Scopes nest safely: overlapping activities keep the indicator on until the last one ends.",
}, async () => {
  const token = await activityControl.begin();
  return { content: [{ type: "text", text: JSON.stringify({ token }) }] };
});

server.registerTool("end_activity", {
  description: "End an interaction-indicator scope started by begin_activity. Pass the token that begin_activity returned. Safe to skip if the client disconnects; the daemon expires abandoned scopes on its own.",
  inputSchema: {
    token: z.string().min(1).describe("Activity token returned by begin_activity"),
  },
}, async ({ token }) => {
  await activityControl.end(token);
  return { content: [{ type: "text", text: JSON.stringify({ ended: true }) }] };
});

server.registerTool("connect_app", {
  description: "OPTIONAL preflight. Every app-taking tool (query_tree, click, fill, screenshot, ...) connects on its own, so you do NOT need to call this first. Call it to (a) check an app is reachable through Accessibility before driving it, (b) see exactly how a fuzzy name resolved, or (c) warm up an Electron app's accessibility tree with a custom readyTimeoutMs. It returns an app handle (\"h_3\") that you can pass as the `app` argument to any other tool to address the same process without re-resolving the name.",
  inputSchema: {
    name: z.string().optional().describe("App name (fuzzy match)"),
    pid: z.number().optional().describe("Process ID"),
    appHandle: z.string().optional().describe("Handle from a previous connect_app; reconnects without re-resolving the name"),
    readyTimeoutMs: z.number().int().nonnegative().optional().describe("Electron accessibility-tree readiness timeout in milliseconds"),
  },
}, async ({ name, pid, appHandle, readyTimeoutMs }) => {
  const target = pid ?? appHandle ?? name;
  if (!target) {
    return { content: [{ type: "text", text: "Error: provide 'name', 'pid', or 'appHandle'" }], isError: true };
  }
  try {
    const app = await client.connect(target, readyTimeoutMs === undefined ? undefined : { readyTimeoutMs });
    const requested = typeof target === "string" ? `Requested “${target}” → ` : "";
    const bundle = app.bundleId ? `, bundle: ${app.bundleId}` : "";
    const aliases = app.aliases.length ? `, aliases: ${app.aliases.join(", ")}` : "";
    const accessibility = app.runtime === "electron"
      ? `, manualAccessibility: ${app.manualAccessibility}, webContent: ${app.webContentReadiness}`
      : "";
    return {
      content: [{
        type: "text",
        text: `${requested}${app.name} (match: ${app.matchKind} via ${app.matchedValue}, pid: ${app.pid}, runtime: ${app.runtime}${bundle}${aliases}${accessibility})\n`
          + `Connected. Pass app: "${app.handle}" to any other tool to reuse this connection.`,
      }],
    };
  } catch (err: unknown) {
    return { content: [{ type: "text", text: formatError("Connect failed", err) }], isError: true };
  }
});

server.registerTool("query_tree", {
  description: "Get an app's accessibility tree, including its menu hierarchy. Use this first; it connects automatically, so a separate connect_app or list_menu_bar call is unnecessary. If Chromium web content is empty, the result explains available screenshot/OCR/menu/keyboard fallbacks.",
  inputSchema: {
    app: appTargetSchema,
    maxDepth: z.number().optional().default(5).describe("Maximum depth to traverse (default: 5)"),
    format: z.enum(["text", "json"]).optional().default("text").describe("Tree output format (default: text)"),
    includeInvisible: z.boolean().optional().default(false).describe("Include structural elements normally filtered from the tree"),
  },
}, async ({ app, maxDepth, format, includeInvisible }) => {
  const handle = await client.connect(app);
  const result = await handle.queryTreeDetailed({ maxDepth, format, includeInvisible });
  const warning = result.diagnostics?.warning
    ? `Warning [degraded_accessibility]: ${result.diagnostics.warning}\n\n`
    : "";
  return { content: [{ type: "text", text: warning + result.tree }] };
});

server.registerTool("list_windows", {
  description: "List WindowServer surfaces owned by an app or its helper processes across macOS Spaces. Returns window IDs, titles, frames, visibility, and whether each surface is capturable. This is read-only and does not activate windows or switch Spaces.",
  inputSchema: {
    app: appTargetSchema,
  },
  annotations: { readOnlyHint: true },
}, async ({ app }) => {
  const handle = await client.connect(app);
  const windows = await handle.listWindows();
  return { content: [{ type: "text", text: JSON.stringify({ windows }, null, 2) }] };
});

server.registerTool("click", {
  description: "Click a UI element. Auto-waits for the element to appear. On Electron/web content, the default 'auto' strategy tries AXPress (and adjacent nodes) then falls back to a synthetic mouse click; override with 'mouse' for canvas-heavy UIs or 'ax' to force a press. Mouse clicks briefly activate the target window, then restore the previous app, window, and cursor.",
  inputSchema: {
    app: appTargetSchema,
    query: querySchema.optional(),
    handleId: z.string().optional().describe("Direct element handle (alternative to query)"),
    timeout: z.number().optional().default(30).describe("Timeout in seconds"),
    strategy: z.enum(["auto", "ax", "mouse"]).optional().describe("Click strategy (default: auto)"),
    waitForIdleMs: z.number().nonnegative().optional().describe("Mouse fallback only: wait for this much user idle time before briefly activating the target window (capped at 5000ms)"),
  },
}, async ({ app, query, handleId, timeout, strategy, waitForIdleMs }) => {
  return withActivity(async () => {
    const handle = await client.connect(app);
    const target = resolveElementTarget(query, handleId);
    await handle.clickTarget(target, {
      timeout: timeout ?? 30,
      ...(strategy ? { strategy } : {}),
      ...(waitForIdleMs !== undefined ? { waitForIdleMs } : {}),
    });
    return { content: [{ type: "text" as const, text: "Clicked successfully" }] };
  });
});

server.registerTool("fill", {
  description: "Set the text value of a field. Auto-waits for the element to appear. On Electron/web content, the default 'auto' strategy writes the AX value then synthesizes keystrokes (so frameworks like React see the input); override with 'keyboard' to force typing or 'ax' to force a direct value write.",
  inputSchema: {
    app: appTargetSchema,
    query: querySchema.optional(),
    handleId: z.string().optional().describe("Direct element handle (alternative to query)"),
    value: z.string().describe("Text value to set"),
    timeout: z.number().optional().default(30).describe("Timeout in seconds"),
    strategy: z.enum(["auto", "ax", "keyboard"]).optional().describe("Fill strategy (default: auto)"),
  },
}, async ({ app, query, handleId, value, timeout, strategy }) => {
  return withActivity(async () => {
    const handle = await client.connect(app);
    const target = resolveElementTarget(query, handleId);
    await handle.fillTarget(target, value, {
      timeout: timeout ?? 30,
      ...(strategy ? { strategy } : {}),
    });
    return { content: [{ type: "text" as const, text: `Set value to "${value}"` }] };
  });
});

server.registerTool("wait_for", {
  description: "Wait for a UI condition. Conditions: 'exists' (default, wait for element to appear), 'value_equals' (wait for specific value), 'value_changes' (wait for any value change), 'enabled' (wait for element to become enabled).",
  inputSchema: {
    app: appTargetSchema,
    query: querySchema.optional().describe("Locator chain to find the element"),
    handleId: z.string().optional().describe("Direct element handle (alternative to query)"),
    timeout: z.number().optional().default(30).describe("Timeout in seconds"),
    pollMs: z.number().optional().describe("Polling interval in ms (default: 500)"),
    condition: z.object({
      kind: z.enum(["exists", "value_equals", "value_changes", "enabled"]).describe("What to wait for"),
      value: z.string().optional().describe("Target value (for value_equals)"),
    }).optional().describe("Wait condition (default: exists)"),
  },
}, async ({ app, query, handleId, timeout, pollMs, condition }) => {
  const handle = await client.connect(app);
  const params: Record<string, unknown> = {
    appHandle: handle.handle,
    timeout: timeout ?? 30,
  };
  if (query) params.query = query;
  if (handleId) params.handleId = handleId;
  if (pollMs) params.pollMs = pollMs;
  if (condition) params.condition = condition;

  const result = await (handle as any).rpc.call("wait_for", params);

  if (result.matched) {
    const kind = condition?.kind ?? "exists";
    if (kind === "value_equals") return { content: [{ type: "text", text: `Value matched: "${result.value}"` }] };
    if (kind === "value_changes") return { content: [{ type: "text", text: `Value changed: "${result.oldValue}" → "${result.newValue}"` }] };
    if (kind === "enabled") return { content: [{ type: "text", text: "Element is now enabled" }] };
  }

  return { content: [{ type: "text", text: `Found: ${result.role ?? "element"} "${result.title ?? ""}" (handle: ${result.handleId ?? "?"})` }] };
});

server.registerTool("press_key", {
  description: 'WARNING: This tool steals focus — it activates the target app window before sending input. Use as a last resort when click/fill cannot achieve the goal (e.g. keyboard shortcuts, arrow-key navigation). Prefer "fill" for text entry and "click" for buttons. Key names: "return", "tab", "escape", "a"-"z", "1"-"9", "f1"-"f12", "up", "down", "left", "right", "space", "delete". Modifiers: "cmd", "shift", "alt", "ctrl".',
  inputSchema: {
    app: appTargetSchema,
    key: z.string().describe("Key name"),
    modifiers: z.array(z.string()).optional().describe('Modifier keys (e.g. ["cmd", "shift"])'),
  },
}, async ({ app, key, modifiers }) => {
  return withActivity(async () => {
    const handle = await client.connect(app);
    await handle.pressKey(key, modifiers);
    return { content: [{ type: "text" as const, text: `Pressed ${modifiers?.length ? modifiers.join("+") + "+" : ""}${key}` }] };
  });
});

server.registerTool("press_keys", {
  description: 'WARNING: This tool steals focus — it activates the target app window before sending input. Use as a last resort when click/fill cannot achieve the goal. Prefer "fill" for text entry and "click" for buttons. Sends a sequence of keyboard inputs in one call. Each step accepts either `key` plus optional `modifiers`, or `text` to type literally, plus optional `delayMs`.',
  inputSchema: {
    app: appTargetSchema,
    keys: z.array(keyStrokeSchema).min(1).describe("Ordered list of key or text items to send"),
  },
}, async ({ app, keys }) => {
  return withActivity(async () => {
    const handle = await client.connect(app);
    await handle.pressKeys(keys as KeyStroke[]);
    return { content: [{ type: "text" as const, text: `Sent ${keys.length} input item${keys.length === 1 ? "" : "s"}` }] };
  });
});

server.registerTool("screenshot", {
  description: "Capture the default visible app window, or select a window returned by list_windows. Explicit selection does not activate the window or switch Spaces; some apps may provide blank content for off-Space windows.",
  inputSchema: {
    app: appTargetSchema,
    windowId: z.number().int().nonnegative().optional().describe("Window ID returned by list_windows"),
    region: z.object({
      x: z.number().describe("X offset in points from the top-left of the window"),
      y: z.number().describe("Y offset in points from the top-left of the window"),
      width: z.number().describe("Width in points"),
      height: z.number().describe("Height in points"),
    }).optional().describe("Optional region to crop (in window-relative points)"),
  },
}, async ({ app, windowId, region }) => {
  return runScreenshotTool(
    {
      connect: (target) => client.connect(target),
      save: saveScreenshotToTempFile,
    },
    {
      app,
      windowId,
      region: region ?? undefined,
    }
  );
});

server.registerTool("extract_text", {
  description: "Extract text from an app window using OCR (Vision framework). Bridges accessibility gaps in apps with poor AX support. Pass either an app name to capture + OCR, or base64 PNG data to OCR directly.",
  inputSchema: {
    app: appTargetSchema.optional().describe("App name or PID (captures a screenshot and runs OCR)"),
    data: z.string().optional().describe("Base64-encoded PNG image to OCR directly (alternative to app)"),
    windowId: z.number().int().nonnegative().optional().describe("Window ID returned by list_windows"),
    region: z.object({
      x: z.number().describe("X offset in points"),
      y: z.number().describe("Y offset in points"),
      width: z.number().describe("Width in points"),
      height: z.number().describe("Height in points"),
    }).optional().describe("Optional region to restrict OCR (only with app, not data)"),
  },
  annotations: { readOnlyHint: true },
}, async ({ app, data, windowId, region }) => {
  if (!app && !data) {
    return { content: [{ type: "text", text: "Provide 'app' or 'data'" }], isError: true };
  }

  const params: { appHandle?: string; data?: string; windowId?: number; region?: typeof region } = {};
  if (data) {
    params.data = data;
  } else if (app) {
    const handle = await client.connect(app);
    params.appHandle = handle.handle;
    if (windowId !== undefined) params.windowId = windowId;
    if (region) params.region = region;
  }

  const rpcResult = await client.extractText(params);

  if (rpcResult.items.length === 0) {
    return { content: [{ type: "text", text: "No text detected." }] };
  }

  const text = rpcResult.items
    .filter((i) => i.confidence > 0.3)
    .map((i) => `${i.text} (${Math.round(i.confidence * 100)}%, at ${Math.round(i.bbox.x)},${Math.round(i.bbox.y)})`)
    .join("\n");
  return { content: [{ type: "text", text }] };
});

server.registerTool("get_element", {
  description: "Find a specific UI element and return its properties (role, title, value, enabled, focused).",
  inputSchema: {
    app: appTargetSchema,
    query: querySchema.optional(),
    handleId: z.string().optional().describe("Direct element handle (alternative to query)"),
  },
}, async ({ app, query, handleId }) => {
  const handle = await client.connect(app);
  const target = resolveElementTarget(query, handleId);
  const info = await handle.getElementInfo(target);
  return {
    content: [{
      type: "text",
      text: JSON.stringify(info, null, 2),
    }],
  };
});

server.registerTool("dump_attributes", {
  description: "Dump all accessibility attributes for a previously resolved element handle.",
  inputSchema: {
    handleId: z.string().describe("Element handle returned by query_tree or get_element"),
  },
  annotations: { readOnlyHint: true },
}, async ({ handleId }) => {
  const attributes = await client.dumpAttributes(handleId);
  return { content: [{ type: "text", text: JSON.stringify(attributes, null, 2) }] };
});

server.registerTool("pin_handle", {
  description: "Pin an element handle to prevent it from expiring (default TTL is 5 minutes). Useful for long-running workflows where you need a stable reference to a panel or control.",
  inputSchema: {
    handleId: z.string().describe("Handle ID to pin (e.g. 'h_42')"),
  },
}, async ({ handleId }) => {
  await (client as any).ensureConnected();
  await (client as any).rpc.call("pin_handle", { handleId });
  return { content: [{ type: "text", text: `Pinned handle: ${handleId}` }] };
});

server.registerTool("unpin_handle", {
  description: "Unpin a previously pinned handle, resuming normal TTL expiry.",
  inputSchema: {
    handleId: z.string().describe("Handle ID to unpin"),
  },
}, async ({ handleId }) => {
  await (client as any).ensureConnected();
  await (client as any).rpc.call("unpin_handle", { handleId });
  return { content: [{ type: "text", text: `Unpinned handle: ${handleId}` }] };
});

server.registerTool("read_form", {
  description: "Read all form-like controls (text fields, sliders, checkboxes, popups, etc.) from a subtree. Returns each control's label, current value, type, editability, and handle. Use this to inspect panel contents without parsing the full tree.",
  inputSchema: {
    app: appTargetSchema,
    query: querySchema.optional().describe("Optional locator chain to scope the search (e.g. to an Inspector panel)"),
    handleId: z.string().optional().describe("Direct subtree handle (alternative to query)"),
    maxDepth: z.number().optional().default(10).describe("Maximum depth to traverse (default: 10)"),
  },
  annotations: { readOnlyHint: true },
}, async ({ app, query, handleId, maxDepth }) => {
  const handle = await client.connect(app);
  const fields = await handle.readForm({
    query: query ?? undefined,
    handleId: handleId ?? undefined,
    maxDepth,
  });
  if (fields.length === 0) {
    return { content: [{ type: "text", text: "No form controls found in the specified subtree." }] };
  }
  const text = fields.map((f) => {
    let line = `[${f.kind}] ${f.label ?? f.title ?? f.identifier ?? "(unlabeled)"}`;
    if (f.value != null) line += ` = ${f.value}`;
    line += ` (${f.role}, handle: ${f.handleId}`;
    if (!f.editable) line += ", read-only";
    if (!f.enabled) line += ", disabled";
    if (f.min != null || f.max != null) line += `, range: ${f.min ?? "?"}–${f.max ?? "?"}`;
    line += ")";
    return line;
  }).join("\n");
  return { content: [{ type: "text", text }] };
});

server.registerTool("select_menu_item", {
  description: "Select a native menu bar item by path (e.g. [\"Track\", \"New Audio Track\"]). Uses the Accessibility API directly, accepts a fuzzy app name or PID, and does not steal focus.",
  inputSchema: {
    app: appTargetSchema,
    menuPath: z.array(z.string()).min(2).describe('Menu path from menu bar, e.g. ["File", "Save"] or ["Track", "New Audio Track"]'),
  },
}, async ({ app, menuPath }) => {
  return withActivity(async () => {
    if (menuPath.length < 2) {
      return { content: [{ type: "text" as const, text: "menuPath must have at least 2 elements (menu bar item + menu item)" }], isError: true };
    }

    try {
      const handle = await client.connect(app);
      const selected = await handle.selectMenuItem(menuPath);
      return { content: [{ type: "text" as const, text: `Selected: ${selected}` }] };
    } catch (err: unknown) {
      return { content: [{ type: "text" as const, text: formatError("Menu action failed", err) }], isError: true };
    }
  });
});

server.registerTool("list_menu_bar", {
  description: "Return a menu-only Accessibility view. query_tree already includes menus, so use this only when that menu section was omitted, truncated, or a compact menu-only result is needed.",
  inputSchema: {
    app: appTargetSchema,
  },
  annotations: { readOnlyHint: true },
}, async ({ app }) => {
  try {
    const handle = await client.connect(app);
    const output = await handle.listMenuBar();
    return { content: [{ type: "text", text: output || "No menu items found." }] };
  } catch (err: unknown) {
    return { content: [{ type: "text", text: formatError("Failed to list menu bar", err) }], isError: true };
  }
});

server.registerTool("run_applescript", {
  description:
    "Run an AppleScript or JavaScript for Automation (JXA) script. Returns the script's output as text. "
    + "Set 'timeout' for work that legitimately runs long (e.g. enumerating many apps); the default is 30 seconds. "
    + "A script that overruns its timeout is stopped and reported as a timeout for that call alone — the server stays "
    + "healthy and other tools keep working.",
  inputSchema: {
    source: z.string().describe("Script source code"),
    language: z.enum(["AppleScript", "JavaScript"]).optional().default("AppleScript").describe("Script language (default: AppleScript)"),
    interaction: z.enum(["interactive", "read_only"]).optional().default("interactive").describe("Whether the script can control apps/input or only inspect state"),
    timeout: z.number()
      .min(SCRIPT_TIMEOUT.minMs / 1_000)
      .max(SCRIPT_TIMEOUT.maxMs / 1_000)
      .optional()
      .default(SCRIPT_TIMEOUT.defaultMs / 1_000)
      .describe(
        `Hard timeout in seconds for this call (default: ${SCRIPT_TIMEOUT.defaultMs / 1_000}, `
        + `max: ${SCRIPT_TIMEOUT.maxMs / 1_000}). The daemon enforces it in a separate process and `
        + "clamps out-of-range values."
      ),
  },
}, async ({ source, language, interaction, timeout }) => {
  const execute = async () => {
    const timeoutMs = scriptTimeoutFromSeconds(timeout);
    try {
      const output = await client.runAppleScript(source, language, {
        interactive: interaction !== "read_only",
        timeoutMs,
      });
      return { content: [{ type: "text" as const, text: output || "(no output)" }] };
    } catch (err: unknown) {
      return {
        content: [{ type: "text" as const, text: formatScriptError(err, timeoutMs / 1_000) }],
        isError: true,
      };
    }
  };
  return interaction === "read_only" ? execute() : withActivity(execute);
});

// --- Shortcuts ---

function getShortcutsList(): string[] {
  try {
    const result = spawnSync("shortcuts", ["list"], { encoding: "utf8", timeout: 10_000 });
    if (result.error || result.status !== 0) return [];
    return (result.stdout ?? "").split("\n").map((l) => l.trim()).filter(Boolean);
  } catch {
    return [];
  }
}

function resolveShortcutName(query: string, shortcuts: string[]): string | null {
  if (!query || shortcuts.length === 0) return null;
  const lowered = query.toLowerCase();
  const exact = shortcuts.find((s) => s.toLowerCase() === lowered);
  if (exact) return exact;
  const normalized = (v: string) => v.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  const normMatch = shortcuts.find((s) => normalized(s) === normalized(query));
  if (normMatch) return normMatch;
  const partial = shortcuts.find((s) => s.toLowerCase().includes(lowered));
  if (partial) return partial;
  return null;
}

server.registerTool("list_shortcuts", {
  description: "List all Apple Shortcuts available on this Mac.",
  annotations: { readOnlyHint: true },
}, async () => {
  const shortcuts = getShortcutsList();
  if (shortcuts.length === 0) {
    return { content: [{ type: "text", text: "No shortcuts found (or Shortcuts app not available)." }] };
  }
  return { content: [{ type: "text", text: shortcuts.map((s) => `- ${s}`).join("\n") }] };
});

server.registerTool("run_shortcut", {
  description: "Run an Apple Shortcut by name. Shortcuts are system-level automations, not tied to any specific app.",
  inputSchema: {
    name: z.string().describe("Shortcut name"),
    input: z.string().optional().describe("Input text to pass to the shortcut"),
  },
}, async ({ name, input }) => {
  return withActivity(async () => {
    const available = getShortcutsList();
    const resolved = resolveShortcutName(name, available);

    if (!resolved) {
      const hint = available.length > 0
        ? `\nAvailable shortcuts:\n${available.slice(0, 30).map((s) => `  - ${s}`).join("\n")}`
        : "";
      return { content: [{ type: "text" as const, text: `Shortcut not found: "${name}"${hint}` }], isError: true };
    }

    const args = ["run", resolved];
    if (input !== undefined) args.push("--input", input);

    const result = spawnSync("shortcuts", args, { encoding: "utf8", timeout: 30_000 });

    if (result.error) {
      return { content: [{ type: "text" as const, text: `Shortcut error: ${result.error.message}` }], isError: true };
    }

    const stdout = (result.stdout ?? "").trim();
    const stderr = (result.stderr ?? "").trim();

    if (result.status !== 0) {
      const msg = stderr || stdout || `Shortcut exited with code ${result.status}`;
      if (/empty shortcut/i.test(msg)) {
        return { content: [{ type: "text" as const, text: `Shortcut "${resolved}" exists but has no actions.` }] };
      }
      return { content: [{ type: "text" as const, text: `Shortcut failed: ${msg}` }], isError: true };
    }

    return {
      content: [{
        type: "text" as const,
        text: JSON.stringify({
          ok: true,
          shortcut: resolved,
          output: stdout || "Shortcut completed.",
        }, null, 2),
      }],
    };
  });
});

// --- Skills ---

interface ScriptMeta {
  file: string;
  name: string;
  description: string;
  usage: string;
}

async function parseScriptMeta(scriptPath: string, fileName: string): Promise<ScriptMeta | null> {
  try {
    const content = await readFile(scriptPath, "utf-8");
    const nameMatch = content.match(/^\/\/\s*@name\s+(.+)$/m);
    const descMatch = content.match(/^\/\/\s*@description\s+(.+)$/m);
    const usageMatch = content.match(/^\/\/\s*@usage\s+(.+)$/m);
    return {
      file: fileName,
      name: nameMatch?.[1]?.trim() ?? fileName.replace(/\.mjs$/, ""),
      description: descMatch?.[1]?.trim() ?? "",
      usage: usageMatch?.[1]?.trim() ?? `node ${fileName}`,
    };
  } catch {
    return null;
  }
}

async function listSkillScripts(skillName: string): Promise<ScriptMeta[]> {
  const scriptsDir = join(SKILLS_DIR, skillName, "scripts");
  try {
    const entries = await readdir(scriptsDir, { withFileTypes: true });
    const mjsFiles = entries.filter((e) => e.isFile() && e.name.endsWith(".mjs"));
    const scripts = await Promise.all(
      mjsFiles.map((f) => parseScriptMeta(join(scriptsDir, f.name), f.name))
    );
    return scripts.filter(Boolean) as ScriptMeta[];
  } catch {
    return [];
  }
}

interface SkillMeta {
  name: string;
  description: string;
  scripts: ScriptMeta[];
}

async function parseSkillMeta(skillDir: string): Promise<SkillMeta | null> {
  try {
    const content = await readFile(join(SKILLS_DIR, skillDir, "SKILL.md"), "utf-8");
    const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
    let description = `Skill: ${skillDir}`;
    if (fmMatch) {
      const descLine = fmMatch[1].match(/^description:\s*(.+)$/m);
      if (descLine) description = descLine[1].trim();
    }
    const scripts = await listSkillScripts(skillDir);
    return { name: skillDir, description, scripts };
  } catch {
    return null;
  }
}

function formatSkillScripts(scripts: ScriptMeta[]): string {
  if (scripts.length === 0) return "";
  const lines = scripts.map((s) =>
    `  - **${s.name}** (${s.file}): ${s.description}${s.usage ? `\n    Usage: \`${s.usage}\`` : ""}`
  );
  return "\n  Scripts:\n" + lines.join("\n");
}

server.registerTool("list_skills", {
  description: "List available macbeth skills. Each skill has instructions (SKILL.md) and optional runnable scripts.",
  annotations: { readOnlyHint: true },
}, async () => {
  try {
    const entries = await readdir(SKILLS_DIR, { withFileTypes: true });
    const dirs = entries.filter((e) => e.isDirectory());
    const skills = (await Promise.all(dirs.map((d) => parseSkillMeta(d.name)))).filter(Boolean) as SkillMeta[];
    if (skills.length === 0) {
      return { content: [{ type: "text", text: "No skills found in skills/ directory." }] };
    }
    const text = skills.map((s) =>
      `- **${s.name}**: ${s.description}${formatSkillScripts(s.scripts)}`
    ).join("\n");
    return { content: [{ type: "text", text }] };
  } catch {
    return { content: [{ type: "text", text: "No skills/ directory found. Create skills/<name>/SKILL.md to add skills." }], isError: true };
  }
});

server.registerTool("load_skill", {
  description: "Load a skill by name. Returns the SKILL.md instructions and lists any runnable scripts.",
  inputSchema: {
    name: z.string().describe("Skill name (directory name under skills/)"),
  },
  annotations: { readOnlyHint: true },
}, async ({ name }) => {
  try {
    const content = await readFile(join(SKILLS_DIR, name, "SKILL.md"), "utf-8");
    const scripts = await listSkillScripts(name);

    let text = content;
    if (scripts.length > 0) {
      text += "\n\n---\n\n## Runnable Scripts\n\n";
      text += "Use the `run_skill_script` tool to execute these:\n\n";
      text += scripts.map((s) =>
        `- **${s.name}** (\`${s.file}\`): ${s.description}\n  Usage: \`${s.usage}\``
      ).join("\n\n");
    }

    return { content: [{ type: "text", text }] };
  } catch {
    return { content: [{ type: "text", text: `Skill "${name}" not found. Run list_skills to see available skills.` }], isError: true };
  }
});

server.registerTool("run_skill_script", {
  description: "Run a script from a skill's scripts/ directory. Scripts are .mjs files that automate specific workflows using macbeth.",
  inputSchema: {
    skill: z.string().describe("Skill name"),
    script: z.string().describe("Script filename (e.g. 'hello.mjs')"),
    args: z.array(z.string()).optional().describe("Arguments to pass to the script"),
  },
}, async ({ skill, script, args }) => {
  return withActivity(async () => {
    const scriptPath = join(SKILLS_DIR, skill, "scripts", script);

    // Prevent path traversal
    const resolved = resolve(scriptPath);
    if (!resolved.startsWith(resolve(SKILLS_DIR))) {
      return { content: [{ type: "text" as const, text: "Invalid script path." }], isError: true };
    }

    try {
      await readFile(scriptPath);
    } catch {
      return { content: [{ type: "text" as const, text: `Script "${script}" not found in skill "${skill}". Run load_skill to see available scripts.` }], isError: true };
    }

    return new Promise<{ content: Array<{ type: "text"; text: string }>; isError?: boolean }>((res) => {
      execFile("node", [scriptPath, ...(args ?? [])], {
        timeout: 120_000,
        cwd: resolve(SKILLS_DIR, ".."),
      }, (error, stdout, stderr) => {
        const output = [stdout, stderr].filter(Boolean).join("\n").trim();
        if (error) {
          res({ content: [{ type: "text", text: `Script failed:\n${output || error.message}` }], isError: true });
        } else {
          res({ content: [{ type: "text", text: output || "Script completed successfully." }] });
        }
      });
    });
  });
});

// --- Start ---

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);

  process.on("SIGINT", async () => {
    await client.close();
    await server.close();
    process.exit(0);
  });

  process.on("SIGTERM", async () => {
    await client.close();
    await server.close();
    process.exit(0);
  });
}

main().catch((err) => {
  process.stderr.write(`[macbeth-mcp] Fatal: ${err}\n`);
  process.exit(1);
});
