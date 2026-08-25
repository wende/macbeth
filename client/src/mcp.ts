import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { MacbethClient } from "./client.js";
import { createUsageTracker } from "./mcp-usage-log.js";
import { createToolContext, MACBETH_TOOLS } from "./tools.js";
import { readInstalledVersion } from "./update.js";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const INSTALL_DIR = resolve(MODULE_DIR, "..");

const client = new MacbethClient({ verbose: false });
const toolContext = createToolContext({ client, logPrefix: "[macbeth-mcp]" });

const server = new McpServer(
  { name: "macbeth", version: readInstalledVersion(INSTALL_DIR) },
  { capabilities: { tools: {} } }
);

for (const tool of MACBETH_TOOLS) {
  const config: {
    description: string;
    inputSchema?: typeof tool.inputSchema;
    annotations?: { readOnlyHint: boolean };
  } = { description: tool.description };
  if (tool.inputSchema) config.inputSchema = tool.inputSchema;
  if (tool.annotations) config.annotations = tool.annotations;
  server.registerTool(
    tool.name,
    config,
    async (args) => tool.handler(toolContext, (args ?? {}) as Record<string, unknown>)
  );
}

/**
 * Record what each tool call actually costs the model, from the last point
 * before the payload leaves this process.
 *
 * This has to wrap the transport rather than the tool handlers: the handlers
 * return content blocks, but the byte and token cost is a property of the
 * serialized payload, and several tools produce theirs through shared helpers
 * (`toModelPayload`, `runListWindowsTool`) that no single handler owns. Wrapping
 * `send`/`onmessage` measures every tool once, including ones added later, and
 * cannot drift out of sync with the handlers.
 *
 * `server.connect()` installs its own `onmessage`, so this must run after it.
 */
function attachUsageLogging(transport: StdioServerTransport): void {
  const usage = createUsageTracker();
  if (!usage) return;

  const { tracker, writer } = usage;
  const originalSend = transport.send.bind(transport);
  const originalOnMessage = transport.onmessage?.bind(transport);

  transport.onmessage = (message) => {
    tracker.noteRequest(message);
    originalOnMessage?.(message);
  };

  transport.send = async (message) => {
    // Log after the send resolves: a payload that failed to reach the host
    // never entered its context, and counting it would inflate the totals.
    await originalSend(message);
    tracker.noteResponse(message);
  };

  const flush = () => writer.flush();
  process.on("exit", flush);
  process.on("beforeExit", flush);
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  attachUsageLogging(transport);

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
