import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { execFile, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import { MacbethClient } from "./client.js";
import type { KeyStroke } from "./types.js";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const INSTALL_DIR = resolve(MODULE_DIR, "..");
const SKILLS_DIR_CANDIDATES = [
  resolve(INSTALL_DIR, "skills"),
  resolve(INSTALL_DIR, "..", "skills"),
];
const SKILLS_DIR = SKILLS_DIR_CANDIDATES.find(existsSync) ?? SKILLS_DIR_CANDIDATES[0];

const client = new MacbethClient({ verbose: false });

const server = new McpServer(
  { name: "macbeth", version: "0.1.0" },
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

server.registerTool("list_apps", {
  description: "List running macOS apps with accessibility support",
}, async () => {
  const apps = await client.listApps();
  const text = apps
    .map((a) => `${a.name} (pid: ${a.pid}, ${a.runtime})`)
    .join("\n");
  return { content: [{ type: "text", text }] };
});

server.registerTool("connect_app", {
  description: "Connect to a macOS app by name or PID. Returns an app handle for subsequent calls.",
  inputSchema: {
    name: z.string().optional().describe("App name (fuzzy match)"),
    pid: z.number().optional().describe("Process ID"),
  },
}, async ({ name, pid }) => {
  const target = pid ?? name;
  if (!target) {
    return { content: [{ type: "text", text: "Error: provide 'name' or 'pid'" }], isError: true };
  }
  const app = await client.connect(target);
  return {
    content: [{
      type: "text",
      text: `Connected to ${app.name} (pid: ${app.pid}, handle: ${app["appHandle"]})`,
    }],
  };
});

server.registerTool("query_tree", {
  description: "Get the accessibility tree of a connected app as indented text. Use this first to discover element roles, titles, and identifiers before building queries.",
  inputSchema: {
    app: z.string().describe("App name or PID"),
    maxDepth: z.number().optional().default(5).describe("Maximum depth to traverse (default: 5)"),
  },
}, async ({ app, maxDepth }) => {
  const handle = await client.connect(app);
  const tree = await handle.queryTree({ maxDepth });
  return { content: [{ type: "text", text: tree }] };
});

server.registerTool("click", {
  description: "Click a UI element. Auto-waits for the element to appear.",
  inputSchema: {
    app: z.string().describe("App name or PID"),
    query: querySchema,
    timeout: z.number().optional().default(30).describe("Timeout in seconds"),
  },
}, async ({ app, query, timeout }) => {
  const handle = await client.connect(app);
  let loc = handle as ReturnType<typeof handle.locator>;
  for (const step of query) {
    loc = loc.locator(step);
  }
  await loc.click({ timeout: (timeout ?? 30) * 1000 });
  return { content: [{ type: "text", text: "Clicked successfully" }] };
});

server.registerTool("fill", {
  description: "Set the text value of a field. Auto-waits for the element to appear.",
  inputSchema: {
    app: z.string().describe("App name or PID"),
    query: querySchema,
    value: z.string().describe("Text value to set"),
    timeout: z.number().optional().default(30).describe("Timeout in seconds"),
  },
}, async ({ app, query, value, timeout }) => {
  const handle = await client.connect(app);
  let loc = handle as ReturnType<typeof handle.locator>;
  for (const step of query) {
    loc = loc.locator(step);
  }
  await loc.fill(value, { timeout: (timeout ?? 30) * 1000 });
  return { content: [{ type: "text", text: `Set value to "${value}"` }] };
});

server.registerTool("wait_for", {
  description: "Wait for a UI element to appear in the app.",
  inputSchema: {
    app: z.string().describe("App name or PID"),
    query: querySchema,
    timeout: z.number().optional().default(30).describe("Timeout in seconds"),
  },
}, async ({ app, query, timeout }) => {
  const handle = await client.connect(app);
  let loc = handle as ReturnType<typeof handle.locator>;
  for (const step of query) {
    loc = loc.locator(step);
  }
  const info = await loc.waitFor({ timeout: (timeout ?? 30) * 1000 });
  return { content: [{ type: "text", text: `Found: ${info.role} "${info.title ?? ""}" (handle: ${info.handleId})` }] };
});

server.registerTool("press_key", {
  description: 'WARNING: This tool steals focus — it activates the target app window before sending input. Use as a last resort when click/fill cannot achieve the goal (e.g. keyboard shortcuts, arrow-key navigation). Prefer "fill" for text entry and "click" for buttons. Key names: "return", "tab", "escape", "a"-"z", "1"-"9", "f1"-"f12", "up", "down", "left", "right", "space", "delete". Modifiers: "cmd", "shift", "alt", "ctrl".',
  inputSchema: {
    app: z.string().describe("App name or PID"),
    key: z.string().describe("Key name"),
    modifiers: z.array(z.string()).optional().describe('Modifier keys (e.g. ["cmd", "shift"])'),
  },
}, async ({ app, key, modifiers }) => {
  const handle = await client.connect(app);
  await handle.pressKey(key, modifiers);
  return { content: [{ type: "text", text: `Pressed ${modifiers?.length ? modifiers.join("+") + "+" : ""}${key}` }] };
});

server.registerTool("press_keys", {
  description: 'WARNING: This tool steals focus — it activates the target app window before sending input. Use as a last resort when click/fill cannot achieve the goal. Prefer "fill" for text entry and "click" for buttons. Sends a sequence of keyboard inputs in one call. Each step accepts either `key` plus optional `modifiers`, or `text` to type literally, plus optional `delayMs`.',
  inputSchema: {
    app: z.string().describe("App name or PID"),
    keys: z.array(keyStrokeSchema).min(1).describe("Ordered list of key or text items to send"),
  },
}, async ({ app, keys }) => {
  const handle = await client.connect(app);
  await handle.pressKeys(keys as KeyStroke[]);
  return { content: [{ type: "text", text: `Sent ${keys.length} input item${keys.length === 1 ? "" : "s"}` }] };
});

server.registerTool("screenshot", {
  description: "Capture a screenshot of an app window. Returns the image.",
  inputSchema: {
    app: z.string().describe("App name or PID"),
  },
  annotations: { readOnlyHint: true },
}, async ({ app }) => {
  const handle = await client.connect(app);
  const buf = await handle.screenshot();
  return {
    content: [{
      type: "image",
      data: buf.toString("base64"),
      mimeType: "image/png",
    }],
  };
});

server.registerTool("get_element", {
  description: "Find a specific UI element and return its properties (role, title, value, enabled, focused).",
  inputSchema: {
    app: z.string().describe("App name or PID"),
    query: querySchema,
  },
}, async ({ app, query }) => {
  const handle = await client.connect(app);
  let loc = handle as ReturnType<typeof handle.locator>;
  for (const step of query) {
    loc = loc.locator(step);
  }
  const info = await loc.getInfo();
  return {
    content: [{
      type: "text",
      text: JSON.stringify(info, null, 2),
    }],
  };
});

server.registerTool("select_menu_item", {
  description: "Select a menu bar item by path (e.g. [\"Track\", \"New Audio Track\"]). Uses System Events — no focus stealing, no intermediate clicks. Prefer this over click for menu bar actions.",
  inputSchema: {
    app: z.string().describe("App name (must match the process name in System Events)"),
    menuPath: z.array(z.string()).min(1).describe('Menu path from menu bar, e.g. ["File", "Save"] or ["Track", "New Audio Track"]'),
  },
}, async ({ app, menuPath }) => {
  const [topMenu, ...items] = menuPath;
  if (items.length === 0) {
    return { content: [{ type: "text", text: "menuPath must have at least 2 elements (menu bar item + menu item)" }], isError: true };
  }

  // Build the AppleScript chain: menu item "X" of menu 1 of menu bar item "Y" of menu bar 1
  let chain = `menu bar item "${topMenu}" of menu bar 1`;
  for (const item of items) {
    chain = `menu item "${item}" of menu 1 of ${chain}`;
  }

  const source = `tell application "System Events"\ntell process "${app}"\nclick ${chain}\nend tell\nend tell`;

  try {
    await client.runAppleScript(source);
    return { content: [{ type: "text", text: `Selected: ${menuPath.join(" > ")}` }] };
  } catch (err: any) {
    return { content: [{ type: "text", text: `Menu action failed: ${err.message}` }], isError: true };
  }
});

server.registerTool("list_menu_bar", {
  description: "List the full menu bar hierarchy of an app — all menus, items, and submenus — without opening any menus. Use this to discover exact menu item names for select_menu_item.",
  inputSchema: {
    app: z.string().describe("App process name"),
  },
  annotations: { readOnlyHint: true },
}, async ({ app: appName }) => {
  const escaped = appName.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  // Bulk-fetch .name() and .enabled() per menu to minimize Apple Event round-trips
  const script = `
const se = Application("System Events");
const proc = se.processes.byName("${escaped}");
const menuBar = proc.menuBars[0];
function walkMenu(menu, depth) {
  if (depth > 3) return "";
  let result = "";
  const indent = "  ".repeat(depth);
  let names, enableds;
  try { names = menu.menuItems.name(); enableds = menu.menuItems.enabled(); } catch(e) { return ""; }
  for (let i = 0; i < names.length; i++) {
    if (!names[i]) { result += indent + "---\\n"; continue; }
    result += indent + names[i] + (enableds[i] ? "" : " [disabled]") + "\\n";
    try {
      const subs = menu.menuItems[i].menus();
      if (subs.length > 0) result += walkMenu(subs[0], depth + 1);
    } catch(e) {}
  }
  return result;
}
let output = "";
const barNames = menuBar.menuBarItems.name();
for (let i = 0; i < barNames.length; i++) {
  if (barNames[i] === "Apple") continue;
  output += barNames[i] + "\\n";
  try { output += walkMenu(menuBar.menuBarItems[i].menus[0], 1); } catch(e) {}
}
output;`;

  try {
    const output = await client.runAppleScript(script, "JavaScript");
    return { content: [{ type: "text", text: output || "No menu items found." }] };
  } catch (err: any) {
    return { content: [{ type: "text", text: `Failed to list menu bar: ${err.message}` }], isError: true };
  }
});

server.registerTool("run_applescript", {
  description: "Run an AppleScript or JavaScript for Automation (JXA) script. Returns the script's output as text.",
  inputSchema: {
    source: z.string().describe("Script source code"),
    language: z.enum(["AppleScript", "JavaScript"]).optional().default("AppleScript").describe("Script language (default: AppleScript)"),
    timeout: z.number().optional().default(30).describe("Timeout in seconds (default: 30)"),
  },
}, async ({ source, language, timeout }) => {
  const timeoutMs = (timeout ?? 30) * 1000;
  try {
    const output = await Promise.race([
      client.runAppleScript(source, language),
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error(`Script timed out after ${timeout ?? 30}s`)), timeoutMs)
      ),
    ]);
    return { content: [{ type: "text", text: output || "(no output)" }] };
  } catch (err: any) {
    return { content: [{ type: "text", text: `Script failed: ${err.message}` }], isError: true };
  }
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
  const available = getShortcutsList();
  const resolved = resolveShortcutName(name, available);

  if (!resolved) {
    const hint = available.length > 0
      ? `\nAvailable shortcuts:\n${available.slice(0, 30).map((s) => `  - ${s}`).join("\n")}`
      : "";
    return { content: [{ type: "text", text: `Shortcut not found: "${name}"${hint}` }], isError: true };
  }

  const args = ["run", resolved];
  if (input !== undefined) args.push("--input", input);

  const result = spawnSync("shortcuts", args, { encoding: "utf8", timeout: 30_000 });

  if (result.error) {
    return { content: [{ type: "text", text: `Shortcut error: ${result.error.message}` }], isError: true };
  }

  const stdout = (result.stdout ?? "").trim();
  const stderr = (result.stderr ?? "").trim();

  if (result.status !== 0) {
    const msg = stderr || stdout || `Shortcut exited with code ${result.status}`;
    if (/empty shortcut/i.test(msg)) {
      return { content: [{ type: "text", text: `Shortcut "${resolved}" exists but has no actions.` }] };
    }
    return { content: [{ type: "text", text: `Shortcut failed: ${msg}` }], isError: true };
  }

  return {
    content: [{
      type: "text",
      text: JSON.stringify({
        ok: true,
        shortcut: resolved,
        output: stdout || "Shortcut completed.",
      }, null, 2),
    }],
  };
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
  const scriptPath = join(SKILLS_DIR, skill, "scripts", script);

  // Prevent path traversal
  const resolved = resolve(scriptPath);
  if (!resolved.startsWith(resolve(SKILLS_DIR))) {
    return { content: [{ type: "text", text: "Invalid script path." }], isError: true };
  }

  try {
    await readFile(scriptPath);
  } catch {
    return { content: [{ type: "text", text: `Script "${script}" not found in skill "${skill}". Run load_skill to see available scripts.` }], isError: true };
  }

  return new Promise((res) => {
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
