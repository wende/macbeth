/**
 * Shared catalog of Macbeth tools.
 *
 * MCP and the CLI both execute this list. Adding a tool here is what makes it
 * show up in both surfaces; `mcp.ts` must not call `registerTool` itself, and
 * the CLI must not special-case individual tools beyond argv parsing.
 */
import { execFile, spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import { MacbethClient } from "./client.js";
import { describeKeyPress, describeKeyStrokes, formatKeyDispatch } from "./key-dispatch.js";
import { runScreenshotTool } from "./mcp-screenshot.js";
import { runListWindowsTool } from "./mcp-windows.js";
import { runPinHandleTool } from "./mcp-pin.js";
import {
  listSkills,
  loadSkill,
  resolveSkillScriptPath,
  resolveSkillsDir,
} from "./mcp-skills.js";
import { saveScreenshotToTempFile } from "./screenshots.js";
import { resolveElementTarget } from "./mcp-target.js";
import { formatAppList } from "./app-target.js";
import { runWithActivity } from "./mcp-activity.js";
import { toModelPayload } from "./mcp-format.js";
import {
  ACTION_TIMEOUT,
  actionRequestTimeoutMs,
  actionTimeoutFromSeconds,
  SCRIPT_TIMEOUT,
  scriptTimeoutFromSeconds,
} from "./timeouts.js";
import type { KeyStroke } from "./types.js";
import { fail, formatError, formatScriptError, ok, type ToolResult } from "./tool-errors.js";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const INSTALL_DIR = resolve(MODULE_DIR, "..");

export function defaultSkillsDir(): string {
  return resolveSkillsDir([
    resolve(INSTALL_DIR, "skills"),
    resolve(INSTALL_DIR, "..", "skills"),
  ]);
}

export interface ToolContext {
  client: MacbethClient;
  skillsDir: string;
  withActivity<T>(operation: () => Promise<T>): Promise<T>;
}

export interface ToolDefinition {
  name: string;
  description: string;
  inputSchema?: Record<string, z.ZodTypeAny>;
  annotations?: { readOnlyHint: boolean };
  handler: (ctx: ToolContext, args: Record<string, unknown>) => Promise<ToolResult>;
}

export function createToolContext(options?: {
  client?: MacbethClient;
  skillsDir?: string;
  logPrefix?: string;
}): ToolContext {
  let client = options?.client;
  const getClient = (): MacbethClient => {
    client ??= new MacbethClient({ verbose: false });
    return client;
  };
  const logPrefix = options?.logPrefix ?? "[macbeth]";
  const activityControl = {
    begin: () => getClient().beginActivity(),
    end: (token: string) => getClient().endActivity(token),
  };
  return {
    get client() {
      return getClient();
    },
    skillsDir: options?.skillsDir ?? defaultSkillsDir(),
    withActivity: <T>(operation: () => Promise<T>) =>
      runWithActivity(activityControl, operation, (error) => {
        const detail = error instanceof Error ? error.message : String(error);
        process.stderr.write(`${logPrefix} Glow activity signal failed: ${detail}\n`);
      }),
  };
}

const querySchema = z
  .array(
    z.object({
      role: z.string().optional().describe("AX role (e.g. 'button', 'window', 'text_field')"),
      title: z.string().optional().describe("Element title to match"),
      identifier: z.string().optional().describe("AX identifier to match"),
      titlePattern: z.string().optional().describe("Regex pattern to match against element title"),
      index: z.number().int().nonnegative().optional().describe("Which match to select when multiple elements match (0-based, default 0)"),
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

const appTargetSchema = z
  .union([z.string(), z.number()])
  .describe('App name (fuzzy), PID, or an app handle returned by connect_app (e.g. "h_3")');

const actionTimeoutSchema = z.number()
  .min(ACTION_TIMEOUT.minMs / 1_000)
  .max(ACTION_TIMEOUT.maxMs / 1_000)
  .optional()
  .default(ACTION_TIMEOUT.defaultMs / 1_000)
  .describe("Timeout in seconds");

function screenshotRegionSchema(windowRelative: boolean) {
  return z.object({
    x: z.number().describe(windowRelative
      ? "X offset in points from the top-left of the window"
      : "X offset in points"),
    y: z.number().describe(windowRelative
      ? "Y offset in points from the top-left of the window"
      : "Y offset in points"),
    width: z.number().describe("Width in points"),
    height: z.number().describe("Height in points"),
  });
}

function asAppTarget(value: unknown): string | number {
  if (typeof value === "string" || typeof value === "number") return value;
  throw new Error("app must be a string or number");
}

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

export const MACBETH_TOOLS: ToolDefinition[] = [
  {
    name: "list_apps",
    description: "List running macOS apps, split into the ones that are currently reachable through the Accessibility API and the ones that are running but will fail to connect (launchers, helper processes, apps that never implement AX). Blocked entries carry the AX error code, what it means, and what to do instead.",
    annotations: { readOnlyHint: true },
    handler: async (ctx) => ok(formatAppList(await ctx.client.listApps())),
  },
  {
    name: "list_daemon_methods",
    description: "List every JSON-RPC method registered by the daemon. Used to verify that daemon capabilities are exposed through MCP.",
    annotations: { readOnlyHint: true },
    handler: async (ctx) => ok(toModelPayload({ methods: await ctx.client.listDaemonMethods() })),
  },
  {
    name: "begin_activity",
    description:
      "Turn on the on-screen interaction indicator before you control the computer through some OTHER tool (a different MCP server, computer-use, a shell script) that Macbeth cannot see. Macbeth's own click/fill/press_key/run_applescript tools already show the indicator, so you do NOT need this for them. Returns a token; you MUST call end_activity with that token when the external work finishes (a crashed or disconnected client is cleaned up automatically after a timeout). Scopes nest safely: overlapping activities keep the indicator on until the last one ends.",
    handler: async (ctx) => ok(toModelPayload({ token: await ctx.client.beginActivity() })),
  },
  {
    name: "end_activity",
    description: "End an interaction-indicator scope started by begin_activity. Pass the token that begin_activity returned. Safe to skip if the client disconnects; the daemon expires abandoned scopes on its own.",
    inputSchema: {
      token: z.string().min(1).describe("Activity token returned by begin_activity"),
    },
    handler: async (ctx, { token }) => {
      await ctx.client.endActivity(String(token));
      return ok(toModelPayload({ ended: true }));
    },
  },
  {
    name: "connect_app",
    description: "OPTIONAL preflight. Every app-taking tool (query_tree, click, fill, screenshot, ...) connects on its own, so you do NOT need to call this first. Call it to (a) check an app is reachable through Accessibility before driving it, (b) see exactly how a fuzzy name resolved, or (c) warm up an Electron app's accessibility tree with a custom readyTimeoutMs. It returns an app handle (\"h_3\") that you can pass as the `app` argument to any other tool to address the same process without re-resolving the name.",
    inputSchema: {
      name: z.string().optional().describe("App name (fuzzy match)"),
      pid: z.number().optional().describe("Process ID"),
      appHandle: z.string().optional().describe("Handle from a previous connect_app; reconnects without re-resolving the name"),
      readyTimeoutMs: z.number().int().nonnegative().optional().describe("Electron accessibility-tree readiness timeout in milliseconds"),
    },
    handler: async (ctx, { name, pid, appHandle, readyTimeoutMs }) => {
      const target = (pid as number | undefined) ?? (appHandle as string | undefined) ?? (name as string | undefined);
      if (!target) {
        return fail("Error: provide 'name', 'pid', or 'appHandle'");
      }
      try {
        const app = await ctx.client.connect(
          target,
          readyTimeoutMs === undefined ? undefined : { readyTimeoutMs: readyTimeoutMs as number }
        );
        const requested = typeof target === "string" ? `Requested “${target}” → ` : "";
        const bundle = app.bundleId ? `, bundle: ${app.bundleId}` : "";
        const aliases = app.aliases.length ? `, aliases: ${app.aliases.join(", ")}` : "";
        const accessibility = app.runtime === "electron"
          ? `, manualAccessibility: ${app.manualAccessibility}, webContent: ${app.webContentReadiness}`
          : "";
        return ok(
          `${requested}${app.name} (match: ${app.matchKind} via ${app.matchedValue}, pid: ${app.pid}, runtime: ${app.runtime}${bundle}${aliases}${accessibility})\n`
            + `Connected. Pass app: "${app.handle}" to any other tool to reuse this connection.`
        );
      } catch (err: unknown) {
        return fail(formatError("Connect failed", err));
      }
    },
  },
  {
    name: "query_tree",
    description: "Get an app's accessibility tree, including its menu hierarchy. Use this first; it connects automatically, so a separate connect_app or list_menu_bar call is unnecessary. Element handles (h_N) are stable: the same element keeps the same handle across calls, so handles you already have stay valid and you can plan several actions from one tree instead of re-querying between them. A handle that stops working reports stale_handle (re-query for it) or unknown_handle (it was never issued). If Chromium web content is empty, the result explains available screenshot/OCR/menu/keyboard fallbacks. Start with maxDepth 2–3 + maxNodes ~300 to orient, then drill in by re-querying a parent handleId when you see a truncation marker.",
    inputSchema: {
      app: appTargetSchema,
      handleId: z.string().optional()
        .describe("Element handle to root the walk at (from a prior query_tree truncation marker). Omit to walk from the app."),
      maxDepth: z.number().optional().default(5).describe("Maximum depth to traverse (default: 5)"),
      maxNodes: z.number().int().positive().optional()
        .describe("Cap breadth (visible nodes the walker emits). When the budget runs out, the parent is emitted with a truncation marker that cites its handleId — re-query that handleId with a higher maxNodes to drill deeper. Must be >= 1 when set."),
      format: z.enum(["text", "json"]).optional().default("text").describe("Tree output format (default: text)"),
      includeInvisible: z.boolean().optional().default(false).describe("Include structural elements normally filtered from the tree"),
      pin: z.boolean().optional().describe("Pin every minted handle with a 60-min idle TTL (refreshed on use). Use when you'll return to the handles later rather than immediately."),
    },
    handler: async (ctx, { app, handleId, maxDepth, maxNodes, format, includeInvisible, pin }) => {
      const handle = await ctx.client.connect(asAppTarget(app));
      const result = await handle.queryTreeDetailed({
        handleId: handleId as string | undefined,
        maxDepth: maxDepth as number | undefined,
        maxNodes: maxNodes as number | undefined,
        format: format as "text" | "json" | undefined,
        includeInvisible: includeInvisible as boolean | undefined,
        pin: pin as boolean | undefined,
      });
      const warning = result.diagnostics?.warning
        ? `Warning [degraded_accessibility]: ${result.diagnostics.warning}\n\n`
        : "";
      return ok(warning + result.tree);
    },
  },
  {
    name: "list_windows",
    description:
      "List open windows across macOS Spaces without touching an accessibility tree. "
      + "Omit 'app' to list windows for every running app — that answers \"is app X open, and what is it showing?\" in one call; "
      + "pass 'app' to scope the listing to one app and its helper processes. "
      + "Each entry has windowId, title, ownerName/ownerPid/bundleId, frame, onScreen/active/minimized, AX role/subrole, kind, and whether it is capturable. "
      + "windowId is a WindowServer ID, not an element handle: it has no TTL, ignores pin_handle, and stays valid until the window closes. "
      + "Read-only — it does not activate windows or switch Spaces.",
    inputSchema: {
      app: appTargetSchema.optional().describe('Optional filter: app name (fuzzy), PID, or an app handle (e.g. "h_3"). Omit to list windows for every app.'),
      includeAllSurfaces: z.boolean().optional().default(false)
        .describe("Also return menu-bar strips, overlays, and bookkeeping surfaces (kind != 'window'). Default false."),
      titlePattern: z.string().optional()
        .describe("Case-insensitive regex; a window matches if any of title / ownerName / bundleId matches. Filtering runs before the per-app AX join so filtered-out apps skip that round trip. Invalid pattern returns -32602."),
    },
    annotations: { readOnlyHint: true },
    handler: async (ctx, { app, includeAllSurfaces, titlePattern }) =>
      runListWindowsTool(
        {
          connect: (target) => ctx.client.connect(target),
          listAll: (options) => ctx.client.listWindows(options),
        },
        {
          app: app as string | number | undefined,
          includeAllSurfaces: includeAllSurfaces as boolean | undefined,
          titlePattern: titlePattern as string | undefined,
        }
      ),
  },
  {
    name: "click",
    description: "Click a UI element. Auto-waits for the element to appear. On Electron/web content, the default 'auto' strategy tries AXPress (and adjacent nodes) then falls back to a synthetic mouse click; override with 'mouse' for canvas-heavy UIs or 'ax' to force a press. Mouse clicks briefly activate the target window, then restore the previous app, window, and cursor.",
    inputSchema: {
      app: appTargetSchema,
      query: querySchema.optional(),
      handleId: z.string().optional().describe("Direct element handle (alternative to query)"),
      timeout: actionTimeoutSchema,
      strategy: z.enum(["auto", "ax", "mouse"]).optional().describe("Click strategy (default: auto)"),
      waitForIdleMs: z.number().nonnegative().optional().describe("Mouse fallback only: wait for this much user idle time before briefly activating the target window (capped at 5000ms)"),
    },
    handler: async (ctx, { app, query, handleId, timeout, strategy, waitForIdleMs }) =>
      ctx.withActivity(async () => {
        const handle = await ctx.client.connect(asAppTarget(app));
        const target = resolveElementTarget(query as never, handleId as string | undefined);
        await handle.clickTarget(target, {
          timeout: timeout as number | undefined,
          ...(strategy ? { strategy: strategy as "auto" | "ax" | "mouse" } : {}),
          ...(waitForIdleMs !== undefined ? { waitForIdleMs: waitForIdleMs as number } : {}),
        });
        return ok("Clicked successfully");
      }),
  },
  {
    name: "fill",
    description: "Set the text value of a field. Auto-waits for the element to appear. On Electron/web content, the default 'auto' strategy writes the AX value then synthesizes keystrokes (so frameworks like React see the input); override with 'keyboard' to force typing or 'ax' to force a direct value write.",
    inputSchema: {
      app: appTargetSchema,
      query: querySchema.optional(),
      handleId: z.string().optional().describe("Direct element handle (alternative to query)"),
      value: z.string().describe("Text value to set"),
      timeout: actionTimeoutSchema,
      strategy: z.enum(["auto", "ax", "keyboard"]).optional().describe("Fill strategy (default: auto)"),
    },
    handler: async (ctx, { app, query, handleId, value, timeout, strategy }) =>
      ctx.withActivity(async () => {
        const handle = await ctx.client.connect(asAppTarget(app));
        const target = resolveElementTarget(query as never, handleId as string | undefined);
        await handle.fillTarget(target, String(value), {
          timeout: timeout as number | undefined,
          ...(strategy ? { strategy: strategy as "auto" | "ax" | "keyboard" } : {}),
        });
        return ok(`Set value to "${value}"`);
      }),
  },
  {
    name: "wait_for",
    description: "Wait for a UI condition. Conditions: 'exists' (default, wait for element to appear), 'value_equals' (wait for specific value), 'value_changes' (wait for any value change), 'enabled' (wait for element to become enabled).",
    inputSchema: {
      app: appTargetSchema,
      query: querySchema.optional().describe("Locator chain to find the element"),
      handleId: z.string().optional().describe("Direct element handle (alternative to query)"),
      timeout: actionTimeoutSchema,
      pollMs: z.number().int().positive().optional().describe("Polling interval in ms (default: 500)"),
      condition: z.object({
        kind: z.enum(["exists", "value_equals", "value_changes", "enabled"]).describe("What to wait for"),
        value: z.string().optional().describe("Target value (for value_equals)"),
      }).optional().describe("Wait condition (default: exists)"),
    },
    handler: async (ctx, { app, query, handleId, timeout, pollMs, condition }) => {
      const handle = await ctx.client.connect(asAppTarget(app));
      const timeoutMs = actionTimeoutFromSeconds(timeout as number | undefined);
      const params: Record<string, unknown> = {
        appHandle: handle.handle,
        timeout: timeoutMs / 1_000,
      };
      if (query) params.query = query;
      if (handleId) params.handleId = handleId;
      if (pollMs !== undefined) params.pollMs = pollMs;
      if (condition) params.condition = condition;

      const result = await (handle as unknown as {
        rpc: { call: (method: string, params: unknown, opts?: { timeoutMs: number }) => Promise<{
          matched?: boolean;
          value?: string;
          oldValue?: string;
          newValue?: string;
          role?: string;
          title?: string;
          handleId?: string;
        }> };
      }).rpc.call(
        "wait_for",
        params,
        { timeoutMs: actionRequestTimeoutMs(timeoutMs) }
      );

      if (result.matched) {
        const kind = (condition as { kind?: string } | undefined)?.kind ?? "exists";
        if (kind === "value_equals") return ok(`Value matched: "${result.value}"`);
        if (kind === "value_changes") return ok(`Value changed: "${result.oldValue}" → "${result.newValue}"`);
        if (kind === "enabled") return ok("Element is now enabled");
      }

      return ok(`Found: ${result.role ?? "element"} "${result.title ?? ""}" (handle: ${result.handleId ?? "?"})`);
    },
  },
  {
    name: "press_key",
    description: 'WARNING: This tool steals focus — it activates the target app window before sending input. Use as a last resort when click/fill cannot achieve the goal (e.g. keyboard shortcuts, arrow-key navigation). Prefer "fill" for text entry and "click" for buttons. Key names: "return", "tab", "escape", "a"-"z", "1"-"9", "f1"-"f12", "up", "down", "left", "right", "space", "delete". Modifiers: "cmd", "shift", "alt", "ctrl". The result reports how far the input got: outcome=dispatched means the events entered the system event stream (the app may still have ignored them); outcome=attempted means even that could not be confirmed. Neither proves the app acted — confirm real effects with query_tree, wait_for, or screenshot instead of resending.',
    inputSchema: {
      app: appTargetSchema,
      key: z.string().describe("Key name"),
      modifiers: z.array(z.string()).optional().describe('Modifier keys (e.g. ["cmd", "shift"])'),
    },
    handler: async (ctx, { app, key, modifiers }) =>
      ctx.withActivity(async () => {
        const handle = await ctx.client.connect(asAppTarget(app));
        const result = await handle.pressKey(String(key), modifiers as string[] | undefined);
        const label = describeKeyPress(String(key), modifiers as string[] | undefined);
        const report = formatKeyDispatch(label, result, `Pressed ${label}`);
        return { content: [{ type: "text" as const, text: report.text }], isError: report.isError };
      }),
  },
  {
    name: "press_keys",
    description: 'WARNING: This tool steals focus — it activates the target app window before sending input. Use as a last resort when click/fill cannot achieve the goal. Prefer "fill" for text entry and "click" for buttons. Sends a sequence of keyboard inputs in one call. Each step accepts either `key` plus optional `modifiers`, or `text` to type literally, plus optional `delayMs`. Reports the same dispatch outcome as press_key, covering the sequence as a whole.',
    inputSchema: {
      app: appTargetSchema,
      keys: z.array(keyStrokeSchema).min(1).describe("Ordered list of key or text items to send"),
    },
    handler: async (ctx, { app, keys }) =>
      ctx.withActivity(async () => {
        const handle = await ctx.client.connect(asAppTarget(app));
        const strokes = keys as KeyStroke[];
        const result = await handle.pressKeys(strokes);
        const report = formatKeyDispatch(
          describeKeyStrokes(strokes),
          result,
          `Sent ${strokes.length} input item${strokes.length === 1 ? "" : "s"}`
        );
        return { content: [{ type: "text" as const, text: report.text }], isError: report.isError };
      }),
  },
  {
    name: "screenshot",
    description: "Capture the default visible app window, or select a window returned by list_windows. Explicit selection does not activate the window or switch Spaces; some apps may provide blank content for off-Space windows.",
    inputSchema: {
      app: appTargetSchema,
      windowId: z.number().int().nonnegative().optional().describe("Window ID returned by list_windows"),
      region: screenshotRegionSchema(true).optional().describe("Optional region to crop (in window-relative points)"),
    },
    handler: async (ctx, { app, windowId, region }) =>
      runScreenshotTool(
        {
          connect: (target) => ctx.client.connect(target),
          save: saveScreenshotToTempFile,
        },
        {
          app: asAppTarget(app),
          windowId: windowId as number | undefined,
          region: region as { x: number; y: number; width: number; height: number } | undefined,
        }
      ),
  },
  {
    name: "extract_text",
    description: "Extract text from an app window using OCR (Vision framework). Bridges accessibility gaps in apps with poor AX support. Pass either an app name to capture + OCR, or base64 PNG data to OCR directly.",
    inputSchema: {
      app: appTargetSchema.optional().describe("App name or PID (captures a screenshot and runs OCR)"),
      data: z.string().optional().describe("Base64-encoded PNG image to OCR directly (alternative to app)"),
      windowId: z.number().int().nonnegative().optional().describe("Window ID returned by list_windows"),
      region: screenshotRegionSchema(false).optional().describe("Optional region to restrict OCR (only with app, not data)"),
    },
    annotations: { readOnlyHint: true },
    handler: async (ctx, { app, data, windowId, region }) => {
      if (!app && !data) {
        return fail("Provide 'app' or 'data'");
      }

      const params: {
        appHandle?: string;
        data?: string;
        windowId?: number;
        region?: { x: number; y: number; width: number; height: number };
      } = {};
      if (data) {
        params.data = String(data);
      } else if (app) {
        const handle = await ctx.client.connect(asAppTarget(app));
        params.appHandle = handle.handle;
        if (windowId !== undefined) params.windowId = windowId as number;
        if (region) params.region = region as { x: number; y: number; width: number; height: number };
      }

      const rpcResult = await ctx.client.extractText(params);

      if (rpcResult.items.length === 0) {
        return ok("No text detected.");
      }

      const text = rpcResult.items
        .filter((i) => i.confidence > 0.3)
        .map((i) => `${i.text} (${Math.round(i.confidence * 100)}%, at ${Math.round(i.bbox.x)},${Math.round(i.bbox.y)})`)
        .join("\n");
      return ok(text);
    },
  },
  {
    name: "get_element",
    description: "Find a specific UI element and return its properties (role, title, value, enabled, focused).",
    inputSchema: {
      app: appTargetSchema,
      query: querySchema.optional(),
      handleId: z.string().optional().describe("Direct element handle (alternative to query)"),
      pin: z.boolean().optional().describe("Pin the returned handle with a 60-min idle TTL (refreshed on use). Ignored when only handleId is given (the existing handle is already in the table)."),
    },
    handler: async (ctx, { app, query, handleId, pin }) => {
      const handle = await ctx.client.connect(asAppTarget(app));
      const target = resolveElementTarget(query as never, handleId as string | undefined);
      const info = await handle.getElementInfo(target, pin as boolean | undefined);
      return ok(toModelPayload(info));
    },
  },
  {
    name: "dump_attributes",
    description: "Dump all accessibility attributes for a previously resolved element handle.",
    inputSchema: {
      handleId: z.string().describe("Element handle returned by query_tree or get_element"),
    },
    annotations: { readOnlyHint: true },
    handler: async (ctx, { handleId }) =>
      ok(toModelPayload(await ctx.client.dumpAttributes(String(handleId)))),
  },
  {
    name: "pin_handle",
    description: "Extend a handle's idle TTL to 60 minutes (refreshed on each use). Pins are finite — abandoned handles age out on their own, so there is no unpin. Prefer `pin: true` on read_form/query_tree/get_element when you know at mint time; use this tool when you decide later, or when pinning a set of handles together via `handleIds`.",
    inputSchema: {
      handleId: z.string().optional().describe("Single handle ID to pin (e.g. 'h_42'). Mutually exclusive with handleIds."),
      handleIds: z.array(z.string()).optional().describe("Bulk pin — returns a per-id result map with `true` on success or `{ error: 'stale_handle: <reason>' | 'unknown_handle' }` on failure."),
    },
    handler: async (ctx, { handleId, handleIds }) =>
      runPinHandleTool(
        { pinHandle: (ids) => ctx.client.pinHandle(ids) },
        { handleId: handleId as string | undefined, handleIds: handleIds as string[] | undefined }
      ),
  },
  {
    name: "read_form",
    description: "Read all form-like controls (text fields, sliders, checkboxes, popups, etc.) from a subtree. Returns each control's label, current value, type, editability, and handle. Use this to inspect panel contents without parsing the full tree. Pass `pin: true` to pin every returned field handle in one call — the cheap path for 'I'm about to fill this form'.",
    inputSchema: {
      app: appTargetSchema,
      query: querySchema.optional().describe("Optional locator chain to scope the search (e.g. to an Inspector panel)"),
      handleId: z.string().optional().describe("Direct subtree handle (alternative to query)"),
      maxDepth: z.number().optional().default(10).describe("Maximum depth to traverse (default: 10)"),
      pin: z.boolean().optional().describe("Pin every returned field handle with a 60-min idle TTL (refreshed on use). One call covers the whole form."),
    },
    annotations: { readOnlyHint: true },
    handler: async (ctx, { app, query, handleId, maxDepth, pin }) => {
      const handle = await ctx.client.connect(asAppTarget(app));
      const fields = await handle.readForm({
        query: (query as never) ?? undefined,
        handleId: (handleId as string | undefined) ?? undefined,
        maxDepth: maxDepth as number | undefined,
        pin: pin as boolean | undefined,
      });
      if (fields.length === 0) {
        return ok("No form controls found in the specified subtree.");
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
      return ok(text);
    },
  },
  {
    name: "select_menu_item",
    description: "Select a native menu bar item by path (e.g. [\"Track\", \"New Audio Track\"]). Uses the Accessibility API directly, accepts a fuzzy app name or PID, and does not steal focus.",
    inputSchema: {
      app: appTargetSchema,
      menuPath: z.array(z.string()).min(2).describe('Menu path from menu bar, e.g. ["File", "Save"] or ["Track", "New Audio Track"]'),
    },
    handler: async (ctx, { app, menuPath }) =>
      ctx.withActivity(async () => {
        const path = menuPath as string[];
        if (path.length < 2) {
          return fail("menuPath must have at least 2 elements (menu bar item + menu item)");
        }

        try {
          const handle = await ctx.client.connect(asAppTarget(app));
          const selected = await handle.selectMenuItem(path);
          return ok(`Selected: ${selected}`);
        } catch (err: unknown) {
          return fail(formatError("Menu action failed", err));
        }
      }),
  },
  {
    name: "list_menu_bar",
    description: "Return a menu-only Accessibility view. query_tree already includes menus, so use this only when that menu section was omitted, truncated, or a compact menu-only result is needed. Pass titlePattern to prune non-matching branches (case-insensitive regex); ancestors of matches are kept.",
    inputSchema: {
      app: appTargetSchema,
      titlePattern: z.string().optional()
        .describe("Case-insensitive regex; matches against each menu item's AX title. Ancestors of matches are kept. Invalid pattern returns -32602."),
    },
    annotations: { readOnlyHint: true },
    handler: async (ctx, { app, titlePattern }) => {
      try {
        const handle = await ctx.client.connect(asAppTarget(app));
        const output = await handle.listMenuBar(
          titlePattern ? { titlePattern: String(titlePattern) } : undefined
        );
        return ok(output || "No menu items found.");
      } catch (err: unknown) {
        return fail(formatError("Failed to list menu bar", err));
      }
    },
  },
  {
    name: "run_applescript",
    description:
      "Run an AppleScript or JavaScript for Automation (JXA) script. Returns the script's output as text. "
      + "The script goes in 'source' (not 'script' or 'code'), and 'language' is exactly \"AppleScript\" or \"JavaScript\" — "
      + "JXA is \"JavaScript\", the string \"jxa\" is not accepted. Examples:\n"
      + "  {\"source\": \"tell application \\\"Finder\\\" to get name of every window\"}\n"
      + "  {\"source\": \"Application('Finder').windows().map(w => w.name()).join(', ')\", \"language\": \"JavaScript\"}\n"
      + "Set 'timeout' for work that legitimately runs long (e.g. enumerating many apps); the default is 30 seconds. "
      + "A script that overruns its timeout is stopped and reported as a timeout for that call alone — the server stays "
      + "healthy and other tools keep working.",
    inputSchema: {
      source: z.string().describe(
        "Script source code. AppleScript example: tell application \"Finder\" to get name of every window. "
        + "JXA example: Application('Finder').windows().map(w => w.name()).join(', ')"
      ),
      language: z.enum(["AppleScript", "JavaScript"]).optional().default("AppleScript")
        .describe("Script language: \"AppleScript\" or \"JavaScript\" (JXA). Default: AppleScript."),
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
    handler: async (ctx, { source, language, interaction, timeout }) => {
      const execute = async () => {
        const timeoutMs = scriptTimeoutFromSeconds(timeout as number | undefined);
        try {
          const output = await ctx.client.runAppleScript(
            String(source),
            language as "AppleScript" | "JavaScript" | undefined,
            {
              interactive: interaction !== "read_only",
              timeoutMs,
            }
          );
          return ok(output || "(no output)");
        } catch (err: unknown) {
          return fail(formatScriptError(err, timeoutMs / 1_000));
        }
      };
      return interaction === "read_only" ? execute() : ctx.withActivity(execute);
    },
  },
  {
    name: "list_shortcuts",
    description: "List all Apple Shortcuts available on this Mac.",
    annotations: { readOnlyHint: true },
    handler: async () => {
      const shortcuts = getShortcutsList();
      if (shortcuts.length === 0) {
        return ok("No shortcuts found (or Shortcuts app not available).");
      }
      return ok(shortcuts.map((s) => `- ${s}`).join("\n"));
    },
  },
  {
    name: "run_shortcut",
    description: "Run an Apple Shortcut by name. Shortcuts are system-level automations, not tied to any specific app.",
    inputSchema: {
      name: z.string().describe("Shortcut name"),
      input: z.string().optional().describe("Input text to pass to the shortcut"),
    },
    handler: async (ctx, { name, input }) =>
      ctx.withActivity(async () => {
        const available = getShortcutsList();
        const resolved = resolveShortcutName(String(name), available);

        if (!resolved) {
          const hint = available.length > 0
            ? `\nAvailable shortcuts:\n${available.slice(0, 30).map((s) => `  - ${s}`).join("\n")}`
            : "";
          return fail(`Shortcut not found: "${name}"${hint}`);
        }

        const args = ["run", resolved];
        if (input !== undefined) args.push("--input", String(input));

        const result = spawnSync("shortcuts", args, { encoding: "utf8", timeout: 30_000 });

        if (result.error) {
          return fail(`Shortcut error: ${result.error.message}`);
        }

        const stdout = (result.stdout ?? "").trim();
        const stderr = (result.stderr ?? "").trim();

        if (result.status !== 0) {
          const msg = stderr || stdout || `Shortcut exited with code ${result.status}`;
          if (/empty shortcut/i.test(msg)) {
            return ok(`Shortcut "${resolved}" exists but has no actions.`);
          }
          return fail(`Shortcut failed: ${msg}`);
        }

        return ok(toModelPayload({
          ok: true,
          shortcut: resolved,
          output: stdout || "Shortcut completed.",
        }));
      }),
  },
  {
    name: "list_skills",
    description: "List available macbeth skills. Each skill has instructions (SKILL.md) and optional runnable scripts. Call load_skill with no arguments for the core macbeth usage guide.",
    annotations: { readOnlyHint: true },
    handler: async (ctx) => listSkills(ctx.skillsDir),
  },
  {
    name: "load_skill",
    description:
      "Load a skill's SKILL.md instructions (and list any runnable scripts). "
      + "Omit `name` (or pass an empty string) to load the core macbeth skill — how to use the MCP tools themselves. "
      + "Pass a directory name under skills/ for an app-specific skill (e.g. \"Safari\", \"electron\").",
    inputSchema: {
      name: z.string().optional().describe(
        'Skill name (directory under skills/). Omit to load the core "macbeth" skill.'
      ),
    },
    annotations: { readOnlyHint: true },
    handler: async (ctx, { name }) => loadSkill(ctx.skillsDir, name as string | undefined),
  },
  {
    name: "run_skill_script",
    description: "Run a script from a skill's scripts/ directory. Scripts are .mjs files that automate specific workflows using macbeth.",
    inputSchema: {
      skill: z.string().describe("Skill name"),
      script: z.string().describe("Script filename (e.g. 'hello.mjs')"),
      args: z.array(z.string()).optional().describe("Arguments to pass to the script"),
    },
    handler: async (ctx, { skill, script, args }) =>
      ctx.withActivity(async () => {
        const resolved = resolveSkillScriptPath(ctx.skillsDir, String(skill), String(script));
        if (!resolved.ok) {
          return fail(resolved.error);
        }
        const scriptPath = resolved.path;

        try {
          await readFile(scriptPath);
        } catch {
          return fail(`Script "${script}" not found in skill "${skill}". Run load_skill to see available scripts.`);
        }

        return new Promise<ToolResult>((res) => {
          execFile("node", [scriptPath, ...((args as string[] | undefined) ?? [])], {
            timeout: 120_000,
            cwd: resolve(ctx.skillsDir, ".."),
          }, (error, stdout, stderr) => {
            const output = [stdout, stderr].filter(Boolean).join("\n").trim();
            if (error) {
              res(fail(`Script failed:\n${output || error.message}`));
            } else {
              res(ok(output || "Script completed successfully."));
            }
          });
        });
      }),
  },
];

export const MACBETH_TOOL_NAMES: string[] = MACBETH_TOOLS.map((tool) => tool.name);

export function normalizeToolName(name: string): string {
  return name.replace(/-/g, "_");
}

export function findTool(name: string): ToolDefinition | undefined {
  const normalized = normalizeToolName(name);
  return MACBETH_TOOLS.find((tool) => tool.name === normalized);
}

export function isToolCommand(name: string): boolean {
  return findTool(name) !== undefined;
}
