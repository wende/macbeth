import { EventEmitter } from "node:events";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it, vi } from "vitest";

const { createConnection, spawn } = vi.hoisted(() => ({
  createConnection: vi.fn(),
  spawn: vi.fn(),
}));

vi.mock("node:net", () => ({ createConnection }));
vi.mock("node:child_process", () => ({ spawn }));

import { DaemonManager } from "../daemon.js";

function socketStub(): EventEmitter & { destroy: ReturnType<typeof vi.fn>; setTimeout: ReturnType<typeof vi.fn> } {
  const socket = new EventEmitter() as EventEmitter & {
    destroy: ReturnType<typeof vi.fn>;
    setTimeout: ReturnType<typeof vi.fn>;
  };
  socket.destroy = vi.fn();
  socket.setTimeout = vi.fn();
  return socket;
}

describe("DaemonManager socket recovery", () => {
  it("distinguishes a connectable daemon socket from stale socket state", async () => {
    const directory = await mkdtemp(join(tmpdir(), "macbeth-daemon-test-"));
    const socketPath = join(directory, "macbeth.sock");
    const manager = new DaemonManager({ socketPath, binaryPath: "/missing/macbethd" });

    try {
      await writeFile(socketPath, "socket marker");
      createConnection.mockImplementation((_options: unknown, onConnect: () => void) => {
        const socket = socketStub();
        queueMicrotask(onConnect);
        return socket;
      });
      expect(await (manager as any).isSocketConnectable()).toBe(true);

      createConnection.mockImplementation(() => {
        const socket = socketStub();
        queueMicrotask(() => socket.emit("error", new Error("ECONNREFUSED")));
        return socket;
      });
      expect(await (manager as any).isSocketConnectable()).toBe(false);
    } finally {
      createConnection.mockReset();
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("reports an early daemon exit instead of waiting for a socket timeout", async () => {
    const directory = await mkdtemp(join(tmpdir(), "macbeth-daemon-exit-test-"));
    const socketPath = join(directory, "macbeth.sock");
    const child = new EventEmitter() as EventEmitter & {
      stderr: EventEmitter & { resume: ReturnType<typeof vi.fn> };
      unref: ReturnType<typeof vi.fn>;
    };
    child.stderr = Object.assign(new EventEmitter(), { resume: vi.fn() });
    child.unref = vi.fn();
    spawn.mockImplementation(() => {
      queueMicrotask(() => {
        child.stderr.emit("data", Buffer.from("signature validation failed\n"));
        child.emit("exit", null, "SIGKILL");
      });
      return child;
    });

    try {
      const manager = new DaemonManager({ socketPath, binaryPath: "/broken/macbethd" });
      await expect(manager.ensureRunning()).rejects.toThrow(
        /signal=SIGKILL[\s\S]*signature validation failed/
      );
    } finally {
      spawn.mockReset();
      await rm(directory, { recursive: true, force: true });
    }
  });
});
