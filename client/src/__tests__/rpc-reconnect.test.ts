import * as net from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { JsonRpcClient } from "../rpc.js";

interface RpcRequest {
  id: number;
  method: string;
}

describe("JSON-RPC reconnect retries", () => {
  let directory: string;
  let socketPath: string;
  let server: net.Server | null = null;
  const sockets = new Set<net.Socket>();

  beforeEach(async () => {
    directory = await mkdtemp(join(tmpdir(), "macbeth-reconnect-test-"));
    socketPath = join(directory, "macbeth.sock");
  });

  afterEach(async () => {
    for (const socket of sockets) socket.destroy();
    sockets.clear();
    if (server) {
      await new Promise<void>((resolve) => server!.close(() => resolve()));
      server = null;
    }
    await rm(directory, { recursive: true, force: true });
  });

  async function startServer(
    onRequest: (request: RpcRequest, socket: net.Socket) => void
  ): Promise<void> {
    server = net.createServer((socket) => {
      sockets.add(socket);
      socket.on("close", () => sockets.delete(socket));
      socket.on("error", () => {});

      let buffer = "";
      socket.on("data", (chunk) => {
        buffer += chunk.toString();
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (line.trim()) onRequest(JSON.parse(line) as RpcRequest, socket);
        }
      });
    });
    await new Promise<void>((resolve, reject) => {
      server!.once("error", reject);
      server!.listen(socketPath, resolve);
    });
  }

  it("does not replay a side-effecting request after its reply is lost", async () => {
    const observed: string[] = [];
    await startServer((request, socket) => {
      observed.push(request.method);
      socket.destroy();
    });

    let reconnects = 0;
    const client = new JsonRpcClient({
      onReconnect: async () => {
        reconnects += 1;
        await client.connect(socketPath);
      },
    });
    await client.connect(socketPath);

    await expect(client.call("click", { appHandle: "h_0", handleId: "h_1" }))
      .rejects.toThrow("Connection closed");
    expect(observed).toEqual(["click"]);
    expect(reconnects).toBe(0);
    client.close();
  });

  it("reconnects and retries a read-only request", async () => {
    const observed: string[] = [];
    await startServer((request, socket) => {
      observed.push(request.method);
      if (observed.length === 1) {
        socket.destroy();
        return;
      }
      socket.write(JSON.stringify({
        jsonrpc: "2.0",
        id: request.id,
        result: { apps: [] },
      }) + "\n");
    });

    const client = new JsonRpcClient({
      onReconnect: () => client.connect(socketPath),
    });
    await client.connect(socketPath);

    await expect(client.call("list_apps")).resolves.toEqual({ apps: [] });
    expect(observed).toEqual(["list_apps", "list_apps"]);
    client.close();
  });
});
