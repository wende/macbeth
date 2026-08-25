import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import type { ZodTypeAny } from "zod";

import {
  CliParseError,
  fieldToFlag,
  materializeToolArgs,
  parseToolArgv,
  schemaIsOptional,
  toolZodObject,
} from "../cli-args.js";
import { formatGlobalHelp, formatToolHelp, runCli } from "../cli.js";
import type { MacbethClient } from "../client.js";
import {
  createToolContext,
  findTool,
  MACBETH_TOOL_NAMES,
  MACBETH_TOOLS,
  type ToolContext,
  type ToolDefinition,
} from "../tools.js";

const rootDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

/**
 * Limitations that are NOT missing tools — they are transport/session differences.
 * The CLI can invoke every MCP tool with the same arguments and handlers.
 * These would need a different product (a persistent MCP-protocol client, not a
 * one-shot argv CLI) to match 1:1:
 *
 * 1. MCP is a long-lived stdio JSON-RPC session. CLI is one-shot argv/stdout.
 *    Host features (session negotiation, per-request cancel IDs, model usage
 *    logging to mcp.log) are not tool capabilities.
 * 2. Nested objects/arrays on the flag path are JSON strings (`--query '[...]'`).
 *    `--json '{...}'` is the lossless MCP-equivalent encoding.
 * 3. `--app 1234` (flag) is a PID; `--json '{"app":"1234"}'` is the name "1234".
 *    Use `--json` when an all-digit name must stay a string.
 * 4. CLI must not call `MacbethClient.close()` (that kills a daemon this process
 *    spawned). The daemon stays warm so handles and activity tokens persist
 *    across invocations, matching TypeScript scripts.
 * 5. Image content blocks, MCP Resources/Prompts, and streaming progress are
 *    unused by Macbeth today. Adding them would need a new CLI UX, not just
 *    another catalog entry.
 */
const FUNDAMENTAL_LIMITATIONS = [
  "stdio MCP session vs one-shot argv",
  "flag path JSON-encodes nested values; --json is lossless",
  "all-digit --app flags coerce to PID",
  "CLI leaves the daemon running (no client.close)",
  "no MCP Resources, Prompts, streaming, or image content blocks",
];

function unwrap(schema: ZodTypeAny): ZodTypeAny {
  let current: ZodTypeAny = schema;
  for (;;) {
    const def = current._def as { typeName?: string; innerType?: ZodTypeAny; schema?: ZodTypeAny };
    if (def.typeName === "ZodOptional" || def.typeName === "ZodDefault" || def.typeName === "ZodNullable") {
      current = def.innerType!;
      continue;
    }
    if (def.typeName === "ZodEffects") {
      current = def.schema!;
      continue;
    }
    return current;
  }
}

function typeName(schema: ZodTypeAny): string {
  return String((unwrap(schema)._def as { typeName?: string }).typeName ?? "");
}

function sampleValue(schema: ZodTypeAny, field: string): unknown {
  const inner = unwrap(schema);
  const name = typeName(schema);
  if (name === "ZodBoolean") return true;
  if (name === "ZodNumber") return field === "timeout" ? 5 : 1;
  if (name === "ZodEnum") {
    const values = (inner._def as { values?: string[] }).values ?? [];
    return values[0] ?? "text";
  }
  if (name === "ZodArray") {
    if (field === "menuPath") return ["File", "Save"];
    if (field === "keys") return [{ key: "a" }];
    if (field === "query") return [{ role: "button", title: "OK" }];
    if (field === "modifiers") return ["cmd"];
    if (field === "handleIds") return ["h_1", "h_2"];
    if (field === "args") return ["--flag"];
    const element = (inner._def as { type: ZodTypeAny }).type;
    return [sampleValue(element, field)];
  }
  if (name === "ZodObject") {
    const shape = (inner._def as { shape: () => Record<string, ZodTypeAny> }).shape();
    const object: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(shape)) {
      object[key] = sampleValue(child, key);
    }
    return object;
  }
  if (name === "ZodUnion") {
    const options = (inner._def as { options?: ZodTypeAny[] }).options ?? [];
    return sampleValue(options[0] ?? schema, field);
  }
  if (field === "handleId" || field === "appHandle" || field === "token") return "h_1";
  if (field === "app") return "Finder";
  if (field === "name") return "Finder";
  if (field === "source") return 'tell application "Finder" to get name';
  if (field === "value") return "hello";
  if (field === "key") return "return";
  if (field === "skill") return "macbeth";
  if (field === "script") return "hello.mjs";
  if (field === "data") return "QQ==";
  if (field === "titlePattern") return "File";
  return "sample";
}

function sampleArgs(tool: ToolDefinition, mode: "required" | "all"): Record<string, unknown> {
  const args: Record<string, unknown> = {};
  for (const [field, schema] of Object.entries(tool.inputSchema ?? {})) {
    if (mode === "required" && schemaIsOptional(schema)) continue;
    args[field] = sampleValue(schema, field);
  }
  if (tool.name === "connect_app" && mode === "required") {
    args.name = "Finder";
  }
  if (tool.name === "extract_text" && mode === "required") {
    args.app = "Finder";
  }
  if (tool.name === "click" || tool.name === "fill" || tool.name === "wait_for" || tool.name === "get_element") {
    if (!args.query && !args.handleId) args.handleId = "h_1";
  }
  if (tool.name === "pin_handle" && mode === "required") {
    args.handleId = "h_1";
  }
  return args;
}

function flagArgvFor(args: Record<string, unknown>): string[] {
  const argv: string[] = [];
  for (const [field, value] of Object.entries(args)) {
    const flag = `--${fieldToFlag(field)}`;
    if (typeof value === "boolean") {
      argv.push(value ? flag : `--no-${fieldToFlag(field)}`);
      continue;
    }
    if (typeof value === "number" || typeof value === "string") {
      argv.push(flag, String(value));
      continue;
    }
    argv.push(flag, JSON.stringify(value));
  }
  return argv;
}

function dummyContext(skillsDir = tmpdir()): ToolContext {
  return {
    client: {} as MacbethClient,
    skillsDir,
    withActivity: (operation) => operation(),
  };
}

const tempDirs: string[] = [];
afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) rmSync(dir, { recursive: true, force: true });
  }
});

async function captureDispatch(tool: ToolDefinition, argv: string[]) {
  const original = tool.handler;
  let captured: Record<string, unknown> | undefined;
  tool.handler = async (_ctx, args) => {
    captured = args;
    return { content: [{ type: "text", text: "ok" }] };
  };
  const stdout: string[] = [];
  const stderr: string[] = [];
  try {
    const status = await runCli([tool.name, ...argv], {
      context: dummyContext(),
      stdout: { write: (chunk) => stdout.push(String(chunk)) },
      stderr: { write: (chunk) => stderr.push(String(chunk)) },
    });
    return { status, captured, stdout: stdout.join(""), stderr: stderr.join("") };
  } finally {
    tool.handler = original;
  }
}

describe("CLI / MCP interface parity", () => {
  it("lists the documented fundamental limitations so they stay visible", () => {
    expect(FUNDAMENTAL_LIMITATIONS.length).toBeGreaterThanOrEqual(4);
  });

  it("exposes every MCP tool as a CLI command", () => {
    expect(MACBETH_TOOL_NAMES).toEqual([
      "list_apps",
      "list_daemon_methods",
      "begin_activity",
      "end_activity",
      "connect_app",
      "query_tree",
      "list_windows",
      "click",
      "fill",
      "wait_for",
      "press_key",
      "press_keys",
      "screenshot",
      "extract_text",
      "get_element",
      "dump_attributes",
      "pin_handle",
      "read_form",
      "select_menu_item",
      "list_menu_bar",
      "run_applescript",
      "list_shortcuts",
      "run_shortcut",
      "list_skills",
      "load_skill",
      "run_skill_script",
    ]);
    const help = formatGlobalHelp();
    for (const name of MACBETH_TOOL_NAMES) {
      expect(findTool(name)?.name).toBe(name);
      expect(findTool(name.replace(/_/g, "-"))?.name).toBe(name);
      expect(help).toContain(name);
    }
  });

  it("does not register MCP tools outside the shared catalog", () => {
    const src = readFileSync(join(rootDir, "client/src/mcp.ts"), "utf8");
    expect(src).toMatch(/for \(const tool of MACBETH_TOOLS\)/);
    expect(src).not.toMatch(/registerTool\(\s*"/);
  });

  it.each(MACBETH_TOOLS)("CLI --help documents every MCP argument for $name", (tool) => {
    const help = formatToolHelp(tool);
    for (const field of Object.keys(tool.inputSchema ?? {})) {
      expect(help).toContain(`--${fieldToFlag(field)}`);
    }
  });

  it.each(MACBETH_TOOLS)("CLI --json round-trips the MCP argument object for $name", (tool) => {
    const sample = sampleArgs(tool, "all");
    const viaJson = materializeToolArgs(tool, sample, { coerce: false });
    const viaFlags = materializeToolArgs(
      tool,
      parseToolArgv(flagArgvFor(sample)).values
    );
    const viaSchema = toolZodObject(tool).parse(sample);
    expect(viaJson).toEqual(viaSchema);
    expect(viaFlags).toEqual(viaSchema);
  });

  it.each(MACBETH_TOOLS)("CLI can invoke $name with the same args MCP would pass", async (tool) => {
    const sample = sampleArgs(tool, "required");
    const expected = materializeToolArgs(tool, sample, { coerce: false });
    const jsonResult = await captureDispatch(tool, ["--json", JSON.stringify(sample)]);
    expect(jsonResult.status, jsonResult.stderr).toBe(0);
    expect(jsonResult.captured).toEqual(expected);
    expect(jsonResult.stdout).toContain("ok");

    const flagResult = await captureDispatch(tool, flagArgvFor(sample));
    expect(flagResult.status, flagResult.stderr).toBe(0);
    expect(flagResult.captured).toEqual(expected);
  });

  it("rejects unknown flags instead of dropping them", () => {
    const click = findTool("click")!;
    expect(() => materializeToolArgs(click, { app: "Finder", handleId: "h_1", nope: true }))
      .toThrow(CliParseError);
  });

  it("runs list_skills through the CLI the same as a direct MCP handler call", async () => {
    const skillsDir = mkdtempSync(join(tmpdir(), "macbeth-cli-skills-"));
    tempDirs.push(skillsDir);
    mkdirSync(join(skillsDir, "macbeth"));
    writeFileSync(
      join(skillsDir, "macbeth", "SKILL.md"),
      "---\nname: macbeth\ndescription: Core guide\n---\n\n# Macbeth\n"
    );
    mkdirSync(join(skillsDir, "Safari"));
    writeFileSync(
      join(skillsDir, "Safari", "SKILL.md"),
      "---\nname: Safari\ndescription: Drive Safari\n---\n\n# Safari\n"
    );

    const ctx = createToolContext({ skillsDir });
    const mcpResult = await findTool("list_skills")!.handler(ctx, {});
    const stdout: string[] = [];
    const status = await runCli(["list_skills"], {
      context: ctx,
      stdout: { write: (chunk) => stdout.push(String(chunk)) },
      stderr: { write: () => {} },
    });
    expect(status).toBe(0);
    expect(stdout.join("").trim()).toBe(mcpResult.content[0]!.text.trim());
    expect(stdout.join("")).toContain("Safari");
    expect(stdout.join("")).toContain("macbeth");
  });
});
