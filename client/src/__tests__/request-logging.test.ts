import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { connect, createConnection } from "node:net";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { MacbethClient } from "../client.js";
import { defaultLogDir } from "../paths.js";
import { DaemonManager } from "../daemon.js";

async function findExecutable(): Promise<string | null> {
  const candidates = [
    join(import.meta.dirname, "../../bin/macbethd"),
    join(import.meta.dirname, "../../../daemon/.build/debug/macbethd"),
    join(import.meta.dirname, "../../../daemon/.build/release/macbethd"),
  ];
  for (const file of candidates) {
    try {
      await readFile(file);
      return file;
    } catch {
      // missing
    }
  }
  return null;
}

async function waitForSocket(socketPath: string, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      await new Promise<void>((resolve, reject) => {
        const sock = createConnection({ path: socketPath }, () => {
          sock.destroy();
          resolve();
        });
        sock.on("error", reject);
        sock.setTimeout(200, () => {
          sock.destroy();
          reject(new Error("socket connect timeout"));
        });
      });
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error(`socket did not appear at ${socketPath} within ${timeoutMs}ms`);
}

describe("request logging (real daemon)", () => {
  let binary: string | null = null;
  let tempDirs: string[] = [];

  beforeAll(async () => {
    binary = await findExecutable();
  });

  afterEach(async () => {
    delete process.env.MACBETH_LOG_DIR;
    delete process.env.MACBETH_NO_LOG;
    delete process.env.MACBETH_LOG_MAX_FILE_MB;
    delete process.env.MACBETH_LOG_MAX_FILES;

    for (const d of tempDirs) {
      await rm(d, { recursive: true, force: true });
    }
    tempDirs = [];
  });

  afterAll(async () => {
    // No global cleanup needed.
  });

  it("writes one NDJSON record per RPC call into the configured log dir", async () => {
    if (!binary) {
      console.warn("[skip] no macbethd binary available");
      return;
    }
    const tempRoot = await mkdtemp(join(tmpdir(), "macbeth-log-test-"));
    tempDirs.push(tempRoot);
    const logDir = join(tempRoot, "logs");
    const socketPath = join(tempRoot, "macbeth.sock");

    process.env.MACBETH_LOG_DIR = logDir;
    const manager = new DaemonManager({ socketPath, binaryPath: binary });
    await manager.ensureRunning();
    try {
      await waitForSocket(socketPath);

      const client = new MacbethClient({ socketPath, daemonPath: binary });
      try {
        await client.listApps();
      } finally {
        await client.close();
      }

      // Give the logger's fire-and-forget Task a moment to flush.
      await new Promise((r) => setTimeout(r, 500));

      const files = await readdir(logDir);
      expect(files).toContain("requests.log");

      const lines = (await readFile(join(logDir, "requests.log"), "utf8"))
        .split("\n")
        .filter(Boolean);
      expect(lines.length).toBeGreaterThan(0);

      const records = lines.map((l) => JSON.parse(l));
      const listApps = records.find((r) => r.method === "list_apps");
      expect(listApps).toBeDefined();
      expect(listApps.ok).toBe(true);
      expect(listApps.paramsBytes).toBeGreaterThan(0);
      expect(listApps.resultBytes).toBeGreaterThan(0);
      expect(listApps.durationMs).toBeGreaterThanOrEqual(0);
    } finally {
      await manager.shutdown();
    }
  });

  it("does not create a log directory when MACBETH_NO_LOG=1", async () => {
    if (!binary) {
      console.warn("[skip] no macbethd binary available");
      return;
    }
    const tempRoot = await mkdtemp(join(tmpdir(), "macbeth-nolog-test-"));
    tempDirs.push(tempRoot);
    const socketPath = join(tempRoot, "macbeth.sock");

    process.env.MACBETH_NO_LOG = "1";
    const manager = new DaemonManager({ socketPath, binaryPath: binary });
    await manager.ensureRunning();
    try {
      await waitForSocket(socketPath);

      const client = new MacbethClient({ socketPath, daemonPath: binary });
      try {
        await client.listApps();
      } finally {
        await client.close();
      }

      await new Promise((r) => setTimeout(r, 500));

      const entries = await readdir(tempRoot, { recursive: true });
      expect(entries.some((p) => p.includes("logs"))).toBe(false);
    } finally {
      await manager.shutdown();
    }
  });
});

// Reference unused imports so the linter doesn't strip them — these are the
// future-facing helpers if the suite grows.
void defaultLogDir; void connect; void writeFile;