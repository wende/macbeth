import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  McpUsageLogWriter,
  McpUsageTracker,
  createUsageTracker,
  resolveUsageLogDir,
  summarizeToolResult,
  type McpUsageRecord,
} from "../mcp-usage-log.js";

const tempDirs: string[] = [];

afterEach(async () => {
  for (const dir of tempDirs.splice(0)) {
    await rm(dir, { recursive: true, force: true });
  }
});

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "macbeth-usage-log-"));
  tempDirs.push(dir);
  return dir;
}

function textResult(text: string) {
  return { content: [{ type: "text", text }] };
}

describe("summarizeToolResult", () => {
  it("counts bytes and estimated tokens for text blocks", () => {
    const summary = summarizeToolResult(textResult("role: button\ntitle: Submit\n"));
    expect(summary.blocks).toBe(1);
    expect(summary.textBytes).toBe(27);
    expect(summary.textTokensEstimated).toBeGreaterThan(0);
    expect(summary.imageBytes).toBe(0);
    expect(summary.ok).toBe(true);
  });

  it("sums across multiple text blocks", () => {
    const single = summarizeToolResult(textResult("abcdefgh"));
    const doubled = summarizeToolResult({
      content: [
        { type: "text", text: "abcdefgh" },
        { type: "text", text: "abcdefgh" },
      ],
    });
    expect(doubled.textBytes).toBe(single.textBytes * 2);
    expect(doubled.blocks).toBe(2);
  });

  it("keeps image bytes out of the token estimate", () => {
    // A text heuristic cannot price an image — the host's vision pipeline sets
    // that cost. Reporting base64 length as tokens would be a fabricated number.
    const summary = summarizeToolResult({
      content: [
        { type: "text", text: "Saved to /tmp/shot.png" },
        { type: "image", data: "aGVsbG8gd29ybGQ=", mimeType: "image/png" },
      ],
    });
    expect(summary.imageBytes).toBe(16);
    expect(summary.textBytes).toBe(22);
    expect(summary.textTokensEstimated).toBeLessThan(20);
  });

  it("marks isError results as not ok", () => {
    expect(summarizeToolResult({ ...textResult("boom"), isError: true }).ok).toBe(false);
  });

  it("tolerates malformed results without throwing", () => {
    for (const value of [undefined, null, {}, { content: "not-an-array" }, { content: [null] }]) {
      expect(() => summarizeToolResult(value)).not.toThrow();
    }
    expect(summarizeToolResult({}).blocks).toBe(0);
  });
});

describe("McpUsageTracker", () => {
  function trackerWith(records: McpUsageRecord[], clock: { now: number }) {
    return new McpUsageTracker((record) => records.push(record), () => clock.now);
  }

  it("joins a tools/call request to its response by id", () => {
    const records: McpUsageRecord[] = [];
    const clock = { now: 1_000 };
    const tracker = trackerWith(records, clock);

    tracker.noteRequest({ id: 7, method: "tools/call", params: { name: "query_tree" } });
    clock.now = 1_250;
    tracker.noteResponse({ id: 7, result: textResult("role: window\n") });

    expect(records).toHaveLength(1);
    expect(records[0]).toMatchObject({
      tool: "query_tree",
      requestID: "7",
      ok: true,
      durationMs: 250,
      blocks: 1,
    });
    expect(records[0].textBytes).toBe(13);
    expect(records[0].textTokensEstimated).toBeGreaterThan(0);
    expect(records[0].tokenEstimator).toBe("heuristic-v1");
  });

  it("measures the text the model reads, not the whole JSON-RPC envelope", () => {
    // This is the distinction the daemon's requests.log misses. payloadBytes is
    // the wire payload; textBytes is the model-facing part, and it is smaller.
    const records: McpUsageRecord[] = [];
    const tracker = trackerWith(records, { now: 0 });
    tracker.noteRequest({ id: 1, method: "tools/call", params: { name: "get_element" } });
    tracker.noteResponse({ jsonrpc: "2.0", id: 1, result: textResult("role: button\n") });

    expect(records[0].textBytes).toBe(13);
    expect(records[0].payloadBytes).toBeGreaterThan(records[0].textBytes);
  });

  it("ignores non-tool traffic", () => {
    const records: McpUsageRecord[] = [];
    const tracker = trackerWith(records, { now: 0 });
    tracker.noteRequest({ id: 1, method: "tools/list" });
    tracker.noteResponse({ id: 1, result: { tools: [] } });
    expect(records).toHaveLength(0);
  });

  it("ignores a response with no matching request", () => {
    const records: McpUsageRecord[] = [];
    const tracker = trackerWith(records, { now: 0 });
    tracker.noteResponse({ id: 99, result: textResult("orphan") });
    expect(records).toHaveLength(0);
  });

  it("emits exactly one record per call", () => {
    const records: McpUsageRecord[] = [];
    const tracker = trackerWith(records, { now: 0 });
    tracker.noteRequest({ id: 1, method: "tools/call", params: { name: "list_apps" } });
    tracker.noteResponse({ id: 1, result: textResult("a") });
    tracker.noteResponse({ id: 1, result: textResult("a") });
    expect(records).toHaveLength(1);
  });

  it("records a protocol-level error as not ok", () => {
    const records: McpUsageRecord[] = [];
    const tracker = trackerWith(records, { now: 0 });
    tracker.noteRequest({ id: 1, method: "tools/call", params: { name: "click" } });
    tracker.noteResponse({ id: 1, error: { code: -32000, message: "nope" } });
    expect(records[0].ok).toBe(false);
    expect(records[0].textBytes).toBe(0);
  });

  it("bounds pending calls so abandoned requests cannot leak", () => {
    const records: McpUsageRecord[] = [];
    const tracker = new McpUsageTracker((r) => records.push(r), () => 0, 4);
    for (let id = 0; id < 20; id += 1) {
      tracker.noteRequest({ id, method: "tools/call", params: { name: "click" } });
    }
    // The four most recent ids survive; earlier ones were evicted.
    tracker.noteResponse({ id: 19, result: textResult("x") });
    tracker.noteResponse({ id: 0, result: textResult("x") });
    expect(records).toHaveLength(1);
    expect(records[0].requestID).toBe("19");
  });

  it("never reports a negative duration when the clock goes backwards", () => {
    const records: McpUsageRecord[] = [];
    const clock = { now: 5_000 };
    const tracker = trackerWith(records, clock);
    tracker.noteRequest({ id: 1, method: "tools/call", params: { name: "click" } });
    clock.now = 4_000;
    tracker.noteResponse({ id: 1, result: textResult("x") });
    expect(records[0].durationMs).toBe(0);
  });
});

describe("resolveUsageLogDir", () => {
  it("honours MACBETH_NO_LOG", () => {
    for (const value of ["1", "true", "YES", "on"]) {
      expect(resolveUsageLogDir({ MACBETH_NO_LOG: value })).toBeNull();
    }
  });

  it("honours MACBETH_LOG_DIR", () => {
    expect(resolveUsageLogDir({ MACBETH_LOG_DIR: "/tmp/logs" })).toBe("/tmp/logs");
  });

  it("falls back to the daemon's cache location", () => {
    const dir = resolveUsageLogDir({});
    expect(dir).toContain("macbeth/logs");
  });

  it("createUsageTracker returns null when logging is disabled", () => {
    expect(createUsageTracker({ MACBETH_NO_LOG: "1" })).toBeNull();
  });
});

describe("McpUsageLogWriter", () => {
  const record = (overrides: Partial<McpUsageRecord> = {}): McpUsageRecord => ({
    ts: "2026-08-11T00:00:00.000Z",
    tool: "query_tree",
    requestID: "1",
    ok: true,
    durationMs: 10,
    payloadBytes: 200,
    textBytes: 100,
    textTokensEstimated: 25,
    imageBytes: 0,
    blocks: 1,
    tokenEstimator: "heuristic-v1",
    ...overrides,
  });

  it("writes one NDJSON line per record", async () => {
    const dir = await tempDir();
    const writer = new McpUsageLogWriter(dir);
    writer.write(record({ requestID: "1" }));
    writer.write(record({ requestID: "2" }));
    await writer.flush();

    const lines = (await readFile(join(dir, "mcp.log"), "utf8")).trim().split("\n");
    expect(lines).toHaveLength(2);
    expect(JSON.parse(lines[0]).requestID).toBe("1");
    expect(JSON.parse(lines[1]).textTokensEstimated).toBe(25);
  });

  it("creates the log directory on demand", async () => {
    const dir = join(await tempDir(), "nested", "logs");
    const writer = new McpUsageLogWriter(dir);
    writer.write(record());
    await writer.flush();
    expect((await readdir(dir)).sort()).toEqual(["mcp.log"]);
  });

  it("rotates once the active file exceeds its cap", async () => {
    const dir = await tempDir();
    const writer = new McpUsageLogWriter(dir, { maxFileBytes: 400, maxFiles: 5 });
    for (let i = 0; i < 12; i += 1) writer.write(record({ requestID: String(i) }));
    await writer.flush();

    const files = await readdir(dir);
    expect(files).toContain("mcp.log");
    expect(files.filter((f) => f.startsWith("mcp-")).length).toBeGreaterThan(0);
  });

  it("keeps at most maxFiles rotated logs", async () => {
    const dir = await tempDir();
    const writer = new McpUsageLogWriter(dir, { maxFileBytes: 300, maxFiles: 2 });
    for (let i = 0; i < 30; i += 1) writer.write(record({ requestID: String(i) }));
    await writer.flush();

    const rotated = (await readdir(dir)).filter((f) => f.startsWith("mcp-"));
    expect(rotated.length).toBeLessThanOrEqual(2);
  });

  it("swallows write failures so logging cannot fail a tool call", async () => {
    // A path that cannot be created: logging must degrade silently, never throw.
    const writer = new McpUsageLogWriter("/dev/null/not-a-directory");
    expect(() => writer.write(record())).not.toThrow();
    await expect(writer.flush()).resolves.toBeUndefined();
  });
});
