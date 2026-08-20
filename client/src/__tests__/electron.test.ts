import { describe, it, expect, vi } from "vitest";
import { Locator } from "../elements.js";
import { JsonRpcError, type JsonRpcClient } from "../rpc.js";

function mockRpc(impl?: (method: string, params?: unknown) => unknown): JsonRpcClient {
  return {
    call: vi.fn().mockImplementation((method: string, params?: unknown) =>
      Promise.resolve(impl ? impl(method, params) : { success: true })
    ),
    connect: vi.fn(),
    close: vi.fn(),
    connected: true,
  } as unknown as JsonRpcClient;
}

describe("web content locators", () => {
  it("webArea() appends an AXWebArea step", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.window("Slack").webArea().button("Send").click();

    expect(rpc.call).toHaveBeenCalledWith("click", {
      appHandle: "h_0",
      query: [
        { role: "window", title: "Slack", identifier: undefined },
        { role: "web_area", title: undefined, identifier: undefined },
        { role: "button", title: "Send", identifier: undefined },
      ],
      timeout: 30,
    }, { timeoutMs: 32_000 });
  });

  it("heading() appends an AXHeading step", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.webArea().heading("Welcome").getInfo();

    const calls = (rpc.call as ReturnType<typeof vi.fn>).mock.calls;
    expect(calls[0][1].query).toEqual([
      { role: "web_area", title: undefined, identifier: undefined },
      { role: "heading", title: "Welcome", identifier: undefined },
    ]);
  });
});

describe("action strategies", () => {
  it("click forwards the strategy option", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.button("Canvas").click({ strategy: "mouse" });

    expect(rpc.call).toHaveBeenCalledWith("click", {
      appHandle: "h_0",
      query: [{ role: "button", title: "Canvas", identifier: undefined }],
      timeout: 30,
      strategy: "mouse",
    }, { timeoutMs: 32_000 });
  });

  it("fill forwards the strategy option", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.textField().fill("hi", { strategy: "keyboard" });

    expect(rpc.call).toHaveBeenCalledWith("fill", {
      appHandle: "h_0",
      query: [{ role: "text_field", title: undefined, identifier: undefined }],
      value: "hi",
      timeout: 30,
      strategy: "keyboard",
    }, { timeoutMs: 32_000 });
  });

  it("omits strategy when not provided (backward compatible)", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.button("OK").click();

    const params = (rpc.call as ReturnType<typeof vi.fn>).mock.calls[0][1];
    expect(params).not.toHaveProperty("strategy");
  });
});

describe("stale-handle re-resolution", () => {
  it("re-resolves a scoped handle when the element was invalidated by a re-render", async () => {
    let stage = 0;
    const rpc = mockRpc((method) => {
      if (method === "get_element") return { handleId: `h_${++stage}`, role: "button", enabled: true, focused: false };
      if (method === "pin_handle") return { pinned: true };
      if (method === "click") {
        // First handle-based click fails as stale; subsequent one succeeds.
        if (stage === 1) {
          throw new JsonRpcError(-32000, "Element reference is no longer valid (stale-element; the app likely re-rendered).");
        }
        return { success: true };
      }
      return { success: true };
    });

    const scoped = await new Locator(rpc, "h_0", [{ role: "button", title: "Send" }]).scope();
    await scoped.click();

    const methods = (rpc.call as ReturnType<typeof vi.fn>).mock.calls.map((c) => c[0]);
    // scope: get_element + pin; click(stale) → rediscover get_element + pin → click(ok)
    expect(methods.filter((m) => m === "get_element").length).toBe(2);
    expect(methods.filter((m) => m === "click").length).toBe(2);
  });

  it("does not retry on unrelated errors", async () => {
    const rpc = mockRpc((method) => {
      if (method === "get_element") return { handleId: "h_1", role: "button", enabled: true, focused: false };
      if (method === "pin_handle") return { pinned: true };
      if (method === "click") throw new JsonRpcError(-32004, "Action failed: something else");
      return { success: true };
    });

    const scoped = await new Locator(rpc, "h_0", [{ role: "button" }]).scope();
    await expect(scoped.click()).rejects.toThrow("Action failed");

    const methods = (rpc.call as ReturnType<typeof vi.fn>).mock.calls.map((c) => c[0]);
    expect(methods.filter((m) => m === "click").length).toBe(1);
  });
});
