import { accessSync, constants } from "node:fs";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import { connect, createConnection } from "node:net";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";

import { MacbethClient } from "../client.js";
import { DaemonManager } from "../daemon.js";

function findExecutable(): string | null {
  const candidates = [
    process.env.MACBETH_DAEMON_PATH,
    join(import.meta.dirname, "../../bin/macbethd"),
    join(import.meta.dirname, "../../../daemon/.build/debug/macbethd"),
    join(import.meta.dirname, "../../../daemon/.build/release/macbethd"),
  ].filter((file): file is string => Boolean(file));
  for (const file of candidates) {
    try {
      accessSync(file, constants.X_OK);
      return file;
    } catch {
      // missing
    }
  }
  return null;
}

const binary = findExecutable() ?? "";
if (!binary && process.env.MACBETH_REQUIRE_DAEMON_TESTS === "1") {
  throw new Error(
    "MACBETH_REQUIRE_DAEMON_TESTS=1 but no executable macbethd binary was found"
  );
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

describe.skipIf(!binary)("request logging (real daemon)", () => {
  let tempDirs: string[] = [];

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

  it("writes one NDJSON record per RPC call into the configured log dir", async () => {
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
    const tempRoot = await mkdtemp(join(tmpdir(), "macbeth-nolog-test-"));
    tempDirs.push(tempRoot);
    const targetLogDir = join(tempRoot, "logs");
    const socketPath = join(tempRoot, "macbeth.sock");

    // Point MACBETH_LOG_DIR at a known temp path. If NO_LOG were ignored, the
    // daemon would honour this and drop requests.log here — fail loudly in
    // that case instead of passing on the absence of a default-path side effect.
    process.env.MACBETH_LOG_DIR = targetLogDir;
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

      // Neither the explicit target dir nor any sibling should contain a log.
      const entries = await readdir(tempRoot, { recursive: true });
      expect(entries).not.toContain("logs");
      expect(entries.some((p) => p.endsWith("requests.log"))).toBe(false);
    } finally {
      await manager.shutdown();
    }
  });

  it("writes to MACBETH_LOG_DIR when MACBETH_NO_LOG is unset", async () => {
    const tempRoot = await mkdtemp(join(tmpdir(), "macbeth-logdir-test-"));
    tempDirs.push(tempRoot);
    const targetLogDir = join(tempRoot, "logs");
    const socketPath = join(tempRoot, "macbeth.sock");

    // Same target as above but NO_LOG unset: the daemon must create
    // requests.log inside the explicit dir, not the default Caches path.
    process.env.MACBETH_LOG_DIR = targetLogDir;
    delete process.env.MACBETH_NO_LOG;
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

      const files = await readdir(targetLogDir);
      expect(files).toContain("requests.log");
    } finally {
      await manager.shutdown();
    }
  });

  it("records a parse-failure entry for malformed JSON", async () => {
    const tempRoot = await mkdtemp(join(tmpdir(), "macbeth-parsefail-test-"));
    tempDirs.push(tempRoot);
    const targetLogDir = join(tempRoot, "logs");
    const socketPath = join(tempRoot, "macbeth.sock");

    process.env.MACBETH_LOG_DIR = targetLogDir;
    delete process.env.MACBETH_NO_LOG;
    const manager = new DaemonManager({ socketPath, binaryPath: binary });
    await manager.ensureRunning();
    try {
      await waitForSocket(socketPath);

      // Write a malformed JSON line directly to the socket. The daemon should
      // respond with a -32700 parse error and log a record with method: null
      // and errorCode: -32700. Using `connect` avoids MacbethClient's normal
      // framing guarantees — exactly what we want to exercise the parse branch.
      const sock = createConnection(socketPath, () => {
        sock.write("not valid json\n");
      });
      let buf = "";
      sock.setEncoding("utf8");
      await new Promise<void>((resolve, reject) => {
        sock.on("data", (chunk: string) => {
          buf += chunk;
          if (buf.includes("\n")) {
            sock.destroy();
            resolve();
          }
        });
        sock.on("error", reject);
        sock.setTimeout(5000, () => {
          sock.destroy();
          reject(new Error("read timed out"));
        });
      });

      // Give the actor a moment to flush the audit record.
      await new Promise((r) => setTimeout(r, 500));

      const lines = (await readFile(join(targetLogDir, "requests.log"), "utf8"))
        .split("\n")
        .filter(Boolean);
      expect(lines.length).toBeGreaterThan(0);

      const records = lines.map((l) => JSON.parse(l));
      const parseFail = records.find((r) => r.errorCode === -32700);

      expect(parseFail).toBeDefined();
      expect(parseFail.ok).toBe(false);
      // method must be present and explicitly null (not omitted) so consumers
      // don't have to branch on key presence.
      expect(Object.prototype.hasOwnProperty.call(parseFail, "method")).toBe(true);
      expect(parseFail.method).toBeNull();
      expect(parseFail.paramsBytes).toBeGreaterThan(0);
      expect(parseFail.resultBytes).toBeGreaterThan(0);
      expect(parseFail.durationMs).toBeGreaterThanOrEqual(0);
    } finally {
      await manager.shutdown();
    }
  });
});

// Reference unused imports so the linter doesn't strip them — connect is for
// a future socket-direct test that would bypass the client wrapper.
void connect;
