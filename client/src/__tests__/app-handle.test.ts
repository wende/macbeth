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

function mockRpcWithResult(result: unknown): JsonRpcClient {
  return {
    call: vi.fn().mockResolvedValue(result),
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

  it("lists and selects menu items through daemon RPCs", async () => {
    const listRpc = mockRpcWithResult({ menu: "File\n  Save" });
    const listApp = new AppHandle(listRpc, "h_0", { name: "Finder", pid: 1, bundleId: null });
    await expect(listApp.listMenuBar()).resolves.toBe("File\n  Save");
    expect(listRpc.call).toHaveBeenCalledWith("list_menu_bar", { appHandle: "h_0" });

    const selectRpc = mockRpcWithResult({ selected: "File > Save" });
    const selectApp = new AppHandle(selectRpc, "h_0", { name: "Finder", pid: 1, bundleId: null });
    await expect(selectApp.selectMenuItem(["File", "Save"])).resolves.toBe("File > Save");
    expect(selectRpc.call).toHaveBeenCalledWith("select_menu_item", {
      appHandle: "h_0",
      menuPath: ["File", "Save"],
    });
  });

  it("returns query tree diagnostics without changing the string API", async () => {
    const rpc = mockRpcWithResult({
      tree: "[web_area \"Codex\"] h:h_1\n",
      diagnostics: {
        runtime: "electron",
        webContent: "empty_web_area",
        warning: "Web content is not inspectable.",
      },
    });
    const app = new AppHandle(rpc, "h_0", {
      name: "ChatGPT",
      pid: 1,
      bundleId: "com.openai.codex",
      runtime: "electron",
    });

    await expect(app.queryTree()).resolves.toContain("web_area");
    await expect(app.queryTreeDetailed()).resolves.toMatchObject({
      diagnostics: { webContent: "empty_web_area" },
    });
  });
});
