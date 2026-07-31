import * as net from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { MacbethClient } from "../client.js";
import { RPC_ERROR_CODES } from "../errors.js";
import { SCRIPT_TIMEOUT } from "../timeouts.js";

/**
 * These tests stand a fake daemon on a real Unix socket and drive a real
 * `MacbethClient` against it. What they pin down is the isolation the MCP
 * server depends on: a script that blows its deadline fails as one operation,
 * leaves the connection usable, and never accumulates into "server unhealthy".
 */

interface RpcRequest {
  id: number;
  method: string;
  params: Record<string, unknown>;
}

type Reply = (payload: Record<string, unknown>) => void;

class FakeDaemon {
  readonly requests: RpcRequest[] = [];
  private server: net.Server;
  private sockets = new Set<net.Socket>();

  constructor(private handle: (request: RpcRequest, reply: Reply) => void) {
    this.server = net.createServer((socket) => {
      this.sockets.add(socket);
      socket.on("error", () => {});
      socket.on("close", () => this.sockets.delete(socket));

      let buffer = "";
      socket.on("data", (chunk) => {
        buffer += chunk.toString();
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (!line.trim()) continue;
          const request = JSON.parse(line) as RpcRequest;
          this.requests.push(request);
          this.handle(request, (payload) => {
            if (socket.destroyed) return;
            socket.write(
              JSON.stringify({ jsonrpc: "2.0", id: request.id, ...payload }) + "\n"
            );
          });
        }
      });
    });
  }

  listen(socketPath: string): Promise<void> {
    return new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(socketPath, () => resolve());
    });
  }

  requestsFor(method: string): RpcRequest[] {
    return this.requests.filter((request) => request.method === method);
  }

  async close(): Promise<void> {
    for (const socket of this.sockets) socket.destroy();
    this.sockets.clear();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }
}

const connectAppResult = {
  appHandle: "app_0",
  name: "Finder",
  pid: 501,
  bundleId: "com.apple.finder",
  runtime: "native",
};

/** Yield to the real event loop so socket I/O can make progress. */
const realSetImmediate = setImmediate;
function ioTick(): Promise<void> {
  return new Promise((resolve) => realSetImmediate(resolve));
}

async function waitUntil(predicate: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 500; i++) {
    if (predicate()) return;
    await ioTick();
  }
  throw new Error(`Timed out waiting for ${label}`);
}

describe("script timeouts are isolated from server health", () => {
  let directory: string;
  let socketPath: string;
  let daemon: FakeDaemon | null = null;
  let client: MacbethClient | null = null;

  beforeEach(async () => {
    directory = await mkdtemp(join(tmpdir(), "macbeth-timeout-test-"));
    socketPath = join(directory, "macbeth.sock");
  });

  afterEach(async () => {
    vi.useRealTimers();
    await client?.close();
    client = null;
    await daemon?.close();
    daemon = null;
    await rm(directory, { recursive: true, force: true });
  });

  async function start(handle: (request: RpcRequest, reply: Reply) => void): Promise<MacbethClient> {
    daemon = new FakeDaemon(handle);
    await daemon.listen(socketPath);
    // A binary path is supplied so the manager never scans for (or spawns) a
    // real daemon: the socket above is already connectable.
    client = new MacbethClient({ socketPath, daemonPath: join(directory, "macbethd") });
    return client;
  }

  it("reports a daemon-enforced timeout as a typed error and keeps serving other calls", async () => {
    const macbeth = await start((request, reply) => {
      if (request.method === "run_applescript") {
        reply({
          error: {
            code: RPC_ERROR_CODES.timeout,
            message: "OSA script execution timed out after 100ms and was stopped",
          },
        });
        return;
      }
      if (request.method === "connect_app") {
        reply({ result: connectAppResult });
        return;
      }
      reply({ result: { apps: [] } });
    });

    for (let attempt = 0; attempt < 3; attempt++) {
      await expect(
        macbeth.runAppleScript("delay 60", "AppleScript", { timeoutMs: 100 })
      ).rejects.toMatchObject({ code: RPC_ERROR_CODES.timeout });
    }

    expect(macbeth.health.operationTimeouts).toBe(3);
    expect(macbeth.health.transportFailures).toBe(0);
    expect(macbeth.health.consecutiveTransportFailures).toBe(0);
    expect(macbeth.health.healthy).toBe(true);

    // The exact regression from the report: connect_app still works after three
    // script timeouts in a row.
    const app = await macbeth.connect("Finder");
    expect(app.name).toBe("Finder");
    expect(macbeth.health.healthy).toBe(true);
  });

  it("recovers on the next script once the slow work is gone", async () => {
    let timeoutsToServe = 3;
    const macbeth = await start((request, reply) => {
      if (request.method !== "run_applescript") {
        reply({ result: connectAppResult });
        return;
      }
      if (timeoutsToServe > 0) {
        timeoutsToServe -= 1;
        reply({
          error: { code: RPC_ERROR_CODES.timeout, message: "OSA script execution timed out" },
        });
        return;
      }
      reply({ result: { output: "hello" } });
    });

    for (let attempt = 0; attempt < 3; attempt++) {
      await expect(
        macbeth.runAppleScript("delay 60", "AppleScript", { timeoutMs: 100 })
      ).rejects.toMatchObject({ code: RPC_ERROR_CODES.timeout });
    }

    await expect(macbeth.runAppleScript("return \"hello\"")).resolves.toBe("hello");
    expect(macbeth.health.healthy).toBe(true);
    expect(macbeth.health.successes).toBeGreaterThan(0);
  });

  it("gives up locally when the daemon never answers, without breaking the connection", async () => {
    const macbeth = await start((request, reply) => {
      // Model a wedged script: no reply at all for run_applescript.
      if (request.method === "run_applescript") return;
      reply({ result: connectAppResult });
    });

    // Concurrent calls, so three independent deadlines run in parallel: one
    // stuck script must not delay another caller.
    const results = await Promise.allSettled(
      [0, 1, 2].map(() =>
        macbeth.runAppleScript("delay 600", "AppleScript", { timeoutMs: SCRIPT_TIMEOUT.minMs })
      )
    );

    for (const result of results) {
      expect(result.status).toBe("rejected");
      const reason = (result as PromiseRejectedResult).reason;
      expect(reason.code).toBe(RPC_ERROR_CODES.timeout);
      expect(reason.data).toMatchObject({ phase: "client_wait", method: "run_applescript" });
    }

    expect(macbeth.health.operationTimeouts).toBe(3);
    expect(macbeth.health.transportFailures).toBe(0);
    expect(macbeth.health.healthy).toBe(true);

    const app = await macbeth.connect("Finder");
    expect(app.pid).toBe(501);
  }, 20_000);

  it("lets a script run well past the 30s default when a larger timeout is asked for", async () => {
    let release: Reply | null = null;
    const macbeth = await start((request, reply) => {
      if (request.method === "run_applescript") {
        release = reply;
        return;
      }
      reply({ result: { apps: [] } });
    });

    // Connect with real timers so socket setup is unaffected by the fake clock.
    await macbeth.listApps();

    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    try {
      const pending = macbeth.runAppleScript("delay 40", "AppleScript", { timeoutMs: 45_000 });
      const failure = pending.catch((err: unknown) => err);

      await waitUntil(() => daemon!.requestsFor("run_applescript").length === 1, "script request");
      expect(daemon!.requestsFor("run_applescript")[0].params.timeoutMs).toBe(45_000);

      // Past the 30s default, and past what a 30s budget would allow: a client
      // that ignored the caller's timeout would have aborted by now.
      vi.advanceTimersByTime(35_000);
      await ioTick();

      release!({ result: { output: "finished after 40s" } });
      vi.useRealTimers();
      await expect(Promise.race([pending, failure])).resolves.toBe("finished after 40s");
      expect(macbeth.health.healthy).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it("clamps an over-long script timeout before it reaches the daemon", async () => {
    const macbeth = await start((request, reply) => {
      if (request.method === "run_applescript") {
        reply({ result: { output: "ok" } });
        return;
      }
      reply({ result: { apps: [] } });
    });

    await macbeth.runAppleScript("return 1", "AppleScript", { timeoutMs: 10 * SCRIPT_TIMEOUT.maxMs });
    expect(daemon!.requestsFor("run_applescript")[0].params.timeoutMs).toBe(SCRIPT_TIMEOUT.maxMs);
  });
});
