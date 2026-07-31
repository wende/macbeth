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
  it("lists windows through the connected app handle", async () => {
    const rpc = mockRpc();
    const windows = [{
      windowId: 42,
      ownerPid: 2,
      ownerName: "Finder",
      bundleId: "com.apple.finder",
      title: "Documents",
      frame: { x: 0, y: 0, width: 800, height: 600 },
      layer: 0,
      onScreen: true,
      active: true,
      capturable: true,
      kind: "window",
      default: true,
    }];
    vi.mocked(rpc.call).mockResolvedValueOnce({ windows });
    const app = new AppHandle(rpc, "h_0", {
      name: "Finder",
      pid: 1,
      bundleId: "com.apple.finder",
    });

    await expect(app.listWindows()).resolves.toEqual(windows);
    expect(rpc.call).toHaveBeenCalledWith("list_windows", {
      appHandle: "h_0",
    });
  });

  it("passes an explicit window ID to screenshots", async () => {
    const rpc = mockRpc();
    vi.mocked(rpc.call).mockResolvedValueOnce({
      data: "cG5n",
      width: 10,
      height: 10,
      format: "png",
    });
    const app = new AppHandle(rpc, "h_0", {
      name: "Finder",
      pid: 1,
      bundleId: "com.apple.finder",
    });

    await app.screenshotRaw({ windowId: 42 });

    expect(rpc.call).toHaveBeenCalledWith("screenshot", {
      appHandle: "h_0",
      windowId: 42,
    });
  });

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

  it("pressKey returns the daemon's dispatch report", async () => {
    const report = {
      success: true,
      outcome: "dispatched",
      dispatched: true,
      verified: false,
      note: "Keyboard events entered the system event stream.",
      warnings: ["target-not-frontmost"],
      keysRequested: 1,
      keysPosted: 1,
      evidence: { sessionKeyDownDelta: 1, accessibilityTrusted: true },
      target: { app: "Finder", pid: 1 },
    };
    const rpc = mockRpcWithResult(report);
    const app = new AppHandle(rpc, "h_0", { name: "Finder", pid: 1, bundleId: null });

    await expect(app.pressKey("return")).resolves.toEqual(report);
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

  it("defaults query tree diagnostics when the daemon omits them", async () => {
    const rpc = mockRpcWithResult({ tree: "[window \"Demo\"]\n" });
    const app = new AppHandle(rpc, "h_0", {
      name: "Demo",
      pid: 1,
      bundleId: null,
      runtime: "native",
    });

    await expect(app.queryTreeDetailed()).resolves.toEqual({
      tree: "[window \"Demo\"]\n",
      diagnostics: { runtime: "native", webContent: "no_web_area" },
    });
    expect(app.handle).toBe("h_0");
  });
});
