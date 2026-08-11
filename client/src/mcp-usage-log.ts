import { appendFile, mkdir, rename, readdir, rm, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { estimateTokens } from "./token-estimate.js";

/**
 * Per-tool-call accounting of what the *model* receives from the MCP server.
 *
 * The daemon's `requests.log` already records byte counts, but it measures the
 * JSON-RPC response leaving the daemon. That is a different payload from the one
 * the model reads: `toModelPayload` converts results to YAML client-side, after
 * the daemon has logged, so a change that halves the model-facing text shows up
 * as zero improvement in `requests.log`. Anything trying to answer "how much
 * context does this tool cost?" from the daemon log is reading the wrong layer.
 *
 * This log closes that gap. It is written by the MCP server process, at the last
 * point before the payload crosses to the host, and it carries an estimated
 * token count alongside bytes — bytes are a poor proxy for context cost, because
 * dense identifiers and base64 pack two to three times more tokens per byte than
 * prose does.
 *
 * Lives beside the daemon log (`~/Library/Caches/macbeth/logs/mcp.log`) and
 * honours the same env knobs, so one `MACBETH_NO_LOG=1` silences both.
 */

/** Bumped when the estimator's output distribution changes, so old records stay interpretable. */
export const TOKEN_ESTIMATOR_VERSION = "heuristic-v1";

export interface McpUsageRecord {
  ts: string;
  tool: string;
  requestID: string | null;
  ok: boolean;
  durationMs: number;
  /** Bytes of the full serialized JSON-RPC response — what crosses the wire. */
  payloadBytes: number;
  /** Bytes of the text blocks only — what the model actually reads. */
  textBytes: number;
  /** Estimated tokens for the text blocks. Approximate by construction; see token-estimate.ts. */
  textTokensEstimated: number;
  /** Bytes of base64 image blocks. Kept apart: a text heuristic cannot price these. */
  imageBytes: number;
  blocks: number;
  tokenEstimator: string;
}

interface ContentBlock {
  type?: unknown;
  text?: unknown;
  data?: unknown;
}

/**
 * Split a tool result into the parts that cost context.
 *
 * Pure, so the accounting is testable without a transport or a filesystem.
 */
export function summarizeToolResult(result: unknown): {
  textBytes: number;
  textTokensEstimated: number;
  imageBytes: number;
  blocks: number;
  ok: boolean;
} {
  const record = (result ?? {}) as { content?: unknown; isError?: unknown };
  const blocks = Array.isArray(record.content) ? (record.content as ContentBlock[]) : [];

  let textBytes = 0;
  let textTokensEstimated = 0;
  let imageBytes = 0;

  for (const block of blocks) {
    if (block?.type === "text" && typeof block.text === "string") {
      textBytes += Buffer.byteLength(block.text, "utf8");
      textTokensEstimated += estimateTokens(block.text);
    } else if (typeof block?.data === "string") {
      // Images and other binary blocks arrive base64-encoded. Their token cost
      // is set by the host's image pipeline, not by this text estimator, so
      // report the size and leave the token column honest.
      imageBytes += Buffer.byteLength(block.data, "utf8");
    }
  }

  return {
    textBytes,
    textTokensEstimated,
    imageBytes,
    blocks: blocks.length,
    ok: record.isError !== true,
  };
}

interface PendingCall {
  tool: string;
  startedAt: number;
}

/**
 * Correlates `tools/call` requests with their responses and emits one record each.
 *
 * The tool name only appears on the request and the payload only on the response,
 * so the two have to be joined by JSON-RPC id. Entries are removed when the
 * response arrives; `maxPending` bounds the map so a host that abandons requests
 * (cancellation, disconnect) cannot grow it without limit.
 */
export class McpUsageTracker {
  private pending = new Map<string, PendingCall>();

  constructor(
    private readonly emit: (record: McpUsageRecord) => void,
    private readonly now: () => number = Date.now,
    private readonly maxPending = 256
  ) {}

  noteRequest(message: unknown): void {
    const msg = message as { id?: unknown; method?: unknown; params?: { name?: unknown } };
    if (msg?.method !== "tools/call") return;
    const id = idOf(msg.id);
    if (id === null) return;
    const tool = typeof msg.params?.name === "string" ? msg.params.name : "unknown";

    if (this.pending.size >= this.maxPending) {
      // Drop the oldest rather than the newest: a stuck entry is the one least
      // likely to ever be answered, and losing it costs one record, not the log.
      const oldest = this.pending.keys().next();
      if (!oldest.done) this.pending.delete(oldest.value);
    }
    this.pending.set(id, { tool, startedAt: this.now() });
  }

  noteResponse(message: unknown): void {
    const msg = message as { id?: unknown; result?: unknown; error?: unknown };
    const id = idOf(msg?.id);
    if (id === null) return;
    const call = this.pending.get(id);
    if (!call) return;
    this.pending.delete(id);

    const summary = summarizeToolResult(msg.result);
    this.emit({
      ts: new Date(this.now()).toISOString(),
      tool: call.tool,
      requestID: id,
      // A protocol-level error carries no content blocks; treat it as not-ok
      // even though `isError` is absent.
      ok: msg.error == null && summary.ok,
      durationMs: Math.max(0, this.now() - call.startedAt),
      payloadBytes: Buffer.byteLength(safeStringify(message), "utf8"),
      textBytes: summary.textBytes,
      textTokensEstimated: summary.textTokensEstimated,
      imageBytes: summary.imageBytes,
      blocks: summary.blocks,
      tokenEstimator: TOKEN_ESTIMATOR_VERSION,
    });
  }
}

function idOf(id: unknown): string | null {
  if (typeof id === "string") return id;
  if (typeof id === "number") return String(id);
  return null;
}

function safeStringify(value: unknown): string {
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return "";
  }
}

/**
 * Resolve the log directory the same way the daemon does, so both logs land
 * together and a single env var moves or silences the pair.
 */
export function resolveUsageLogDir(env: NodeJS.ProcessEnv = process.env): string | null {
  if (isTruthy(env.MACBETH_NO_LOG)) return null;
  const override = env.MACBETH_LOG_DIR?.trim();
  if (override) return override;
  return join(homedir(), "Library", "Caches", "macbeth", "logs");
}

function isTruthy(raw: string | undefined): boolean {
  if (!raw) return false;
  return ["1", "true", "yes", "on"].includes(raw.trim().toLowerCase());
}

/**
 * Append-only NDJSON writer with size-based rotation.
 *
 * Every failure is swallowed. Logging must never turn a working tool call into a
 * failed one — the same rule the daemon's `RequestLogger` follows.
 */
export class McpUsageLogWriter {
  private readonly file: string;
  private readonly maxFileBytes: number;
  private readonly maxFiles: number;
  private bytesWritten: number | null = null;
  private queue: Promise<void> = Promise.resolve();

  constructor(
    private readonly directory: string,
    options: { maxFileBytes?: number; maxFiles?: number } = {}
  ) {
    this.file = join(directory, "mcp.log");
    this.maxFileBytes = options.maxFileBytes ?? 5 * 1024 * 1024;
    this.maxFiles = options.maxFiles ?? 10;
  }

  /**
   * Fire-and-forget. Writes are chained rather than issued concurrently so
   * rotation cannot interleave with an append and split a record across files.
   */
  write(record: McpUsageRecord): void {
    this.queue = this.queue.then(() => this.append(record)).catch(() => {});
  }

  /** Await all queued writes. Used by tests and shutdown. */
  flush(): Promise<void> {
    return this.queue.catch(() => {});
  }

  private async append(record: McpUsageRecord): Promise<void> {
    const line = `${JSON.stringify(record)}\n`;
    const size = Buffer.byteLength(line, "utf8");

    await mkdir(this.directory, { recursive: true });
    if (this.bytesWritten === null) {
      this.bytesWritten = await currentSize(this.file);
    }
    if (this.bytesWritten > 0 && this.bytesWritten + size > this.maxFileBytes) {
      await this.rotate();
      this.bytesWritten = 0;
    }
    await appendFile(this.file, line, "utf8");
    this.bytesWritten += size;
  }

  private async rotate(): Promise<void> {
    const stamp = new Date().toISOString().replace(/:/g, "-");
    let target = join(this.directory, `mcp-${stamp}.log`);
    for (let n = 1; await exists(target); n += 1) {
      target = join(this.directory, `mcp-${stamp}-${n}.log`);
    }
    await rename(this.file, target);
    await this.evict();
  }

  private async evict(): Promise<void> {
    const entries = await readdir(this.directory).catch(() => [] as string[]);
    const rotated = entries
      .filter((name) => name.startsWith("mcp-") && name.endsWith(".log"))
      .sort();
    const excess = rotated.length - this.maxFiles;
    for (const name of rotated.slice(0, Math.max(0, excess))) {
      await rm(join(this.directory, name), { force: true }).catch(() => {});
    }
  }
}

async function currentSize(file: string): Promise<number> {
  try {
    return (await stat(file)).size;
  } catch {
    return 0;
  }
}

async function exists(file: string): Promise<boolean> {
  try {
    await stat(file);
    return true;
  } catch {
    return false;
  }
}

/**
 * Build the tracker the MCP server uses, or `null` when logging is disabled.
 */
export function createUsageTracker(
  env: NodeJS.ProcessEnv = process.env
): { tracker: McpUsageTracker; writer: McpUsageLogWriter } | null {
  const directory = resolveUsageLogDir(env);
  if (!directory) return null;
  const writer = new McpUsageLogWriter(directory, {
    maxFileBytes: megabytes(env.MACBETH_LOG_MAX_FILE_MB),
    maxFiles: positiveInt(env.MACBETH_LOG_MAX_FILES),
  });
  return { tracker: new McpUsageTracker((record) => writer.write(record)), writer };
}

function megabytes(raw: string | undefined): number | undefined {
  const mb = positiveInt(raw);
  return mb === undefined ? undefined : mb * 1024 * 1024;
}

function positiveInt(raw: string | undefined): number | undefined {
  if (!raw) return undefined;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}
