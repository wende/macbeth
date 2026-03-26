import { describe, expect, it, vi } from "vitest";
import { AppHandle } from "../client.js";
import type { JsonRpcClient } from "../rpc.js";

function mockRpc(): JsonRpcClient {
  return {
    call: vi.fn().mockResolvedValue({ success: true }),
    connect: vi.fn(),
    close: vi.fn(),
    connected: true,
  } as unknown as JsonRpcClient;
}

describe("AppHandle", () => {
  it("pressKey sends a single key press", async () => {
    const rpc = mockRpc();
    const app = new AppHandle(rpc, "h_0", { name: "Finder", pid: 1, bundleId: null });

    await app.pressKey("a", ["cmd"]);

    expect(rpc.call).toHaveBeenCalledWith("press_key", {
      appHandle: "h_0",
      key: "a",
      modifiers: ["cmd"],
    });
  });

  it("pressKeys sends the whole key sequence in one RPC call", async () => {
    const rpc = mockRpc();
    const app = new AppHandle(rpc, "h_0", { name: "Finder", pid: 1, bundleId: null });

    await app.pressKeys([
      { key: "l", modifiers: ["cmd"] },
      { key: "a", modifiers: ["cmd"], delayMs: 75 },
      { key: "return" },
    ]);

    expect(rpc.call).toHaveBeenCalledWith("press_keys", {
      appHandle: "h_0",
      keys: [
        { key: "l", modifiers: ["cmd"] },
        { key: "a", modifiers: ["cmd"], delayMs: 75 },
        { key: "return" },
      ],
    });
  });

  it("pressKeys supports text items", async () => {
    const rpc = mockRpc();
    const app = new AppHandle(rpc, "h_0", { name: "Finder", pid: 1, bundleId: null });

    await app.pressKeys([
      { text: "abcd" },
      { key: "return" },
    ]);

    expect(rpc.call).toHaveBeenCalledWith("press_keys", {
      appHandle: "h_0",
      keys: [
        { text: "abcd" },
        { key: "return" },
      ],
    });
  });
});
