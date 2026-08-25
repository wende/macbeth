import { readFileSync } from "node:fs";
import {
  CliParseError,
  fieldToFlag,
  materializeToolArgs,
  parseJsonObject,
  parseToolArgv,
  schemaDescription,
  schemaIsOptional,
  schemaTypeLabel,
} from "./cli-args.js";
import { formatError } from "./tool-errors.js";
import {
  createToolContext,
  findTool,
  isToolCommand,
  MACBETH_TOOLS,
  type ToolContext,
  type ToolDefinition,
} from "./tools.js";

export { isToolCommand, findTool };

function firstSentence(text: string): string {
  const line = text.split("\n")[0] ?? text;
  const match = line.match(/^[^.]+(?:\.(?=\s|$))?/);
  const sentence = (match?.[0] ?? line).trim();
  return sentence.length > 110 ? `${sentence.slice(0, 107)}...` : sentence;
}

export function formatGlobalHelp(): string {
  const tools = MACBETH_TOOLS.map((tool) => {
    const name = tool.name.padEnd(22);
    return `  ${name}${firstSentence(tool.description)}`;
  }).join("\n");

  return `macbeth — open-source Computer Use for macOS
See and operate Mac applications through MCP or TypeScript, including native and Electron interfaces.

Usage:
  macbeth                 Start the MCP server (default; used by LLM agents)
  macbeth doctor          Check macOS Accessibility + Screen Recording permissions
  macbeth update          Update to the latest GitHub release
  macbeth update --check  Report whether an update is available, without installing
  macbeth version         Print the installed version
  macbeth help            Show this help
  macbeth <tool>          Run an MCP tool (same names and arguments as the MCP server)
  macbeth <tool> --json '{...}'
                          Pass arguments as JSON — the CLI equivalent of an MCP tool call
  macbeth <tool> --help   Show one tool's arguments

Tools (parity with the MCP server):
${tools}
`;
}

export function formatToolHelp(tool: ToolDefinition): string {
  const lines = [
    `${tool.name} — ${tool.description}`,
    "",
    "Usage:",
    `  macbeth ${tool.name} [options]`,
    `  macbeth ${tool.name} --json '{...}'`,
    "",
  ];

  const fields = Object.entries(tool.inputSchema ?? {});
  if (fields.length === 0) {
    lines.push("This tool takes no arguments.");
  } else {
    lines.push("Options (same fields as the MCP tool):");
    for (const [field, schema] of fields) {
      const flag = `--${fieldToFlag(field)}`;
      const type = schemaTypeLabel(schema);
      const optional = schemaIsOptional(schema) ? "optional" : "required";
      const desc = schemaDescription(schema);
      lines.push(`  ${flag} <${type}>  (${optional})${desc ? ` ${desc}` : ""}`);
    }
    lines.push("  --json <object>  Pass every argument as a JSON object (MCP-equivalent)");
  }
  lines.push("  --help           Show this help");
  lines.push("");
  return lines.join("\n");
}

export interface RunCliOptions {
  context?: ToolContext;
  stdout?: { write(chunk: string): unknown };
  stderr?: { write(chunk: string): unknown };
  /** Override for `--json -`. Defaults to reading stdin. */
  readStdin?: () => string | Promise<string>;
}

/**
 * Execute `argv` as a CLI tool invocation (no leading `macbeth`).
 * Returns a process exit code.
 *
 * The daemon is left running: handles and activity tokens persist across CLI
 * invocations the same way they do for TypeScript scripts.
 */
export async function runCli(argv: string[], options: RunCliOptions = {}): Promise<number> {
  const stdout = options.stdout ?? process.stdout;
  const stderr = options.stderr ?? process.stderr;

  const [command, ...rest] = argv;
  if (!command || command === "help" || command === "--help" || command === "-h") {
    stdout.write(formatGlobalHelp());
    return 0;
  }

  const tool = findTool(command);
  if (!tool) {
    stderr.write(`Unknown command: ${command}\n\n`);
    stdout.write(formatGlobalHelp());
    return 1;
  }

  try {
    const parsed = parseToolArgv(rest);
    if (parsed.help) {
      stdout.write(formatToolHelp(tool));
      return 0;
    }

    let raw = parsed.values;
    if (parsed.json !== undefined) {
      const jsonText = parsed.json === "-"
        ? await (options.readStdin ?? (() => readFileSync(0, "utf8")))()
        : parsed.json;
      raw = parseJsonObject(jsonText);
    }

    const args = materializeToolArgs(tool, raw, { coerce: parsed.json === undefined });
    const ctx = options.context ?? createToolContext();

    const result = await tool.handler(ctx, args);
    const text = result.content.map((block) => block.text).join("\n");
    if (text) stdout.write(text.endsWith("\n") ? text : `${text}\n`);
    return result.isError ? 1 : 0;
  } catch (err) {
    if (err instanceof CliParseError) {
      stderr.write(`${err.message}\n`);
      stderr.write(`Try \`macbeth ${tool.name} --help\`.\n`);
      return 1;
    }
    stderr.write(`${formatError("Failed", err)}\n`);
    return 1;
  }
}
