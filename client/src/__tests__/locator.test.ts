import { describe, it, expect, vi } from "vitest";
import { Locator } from "../elements.js";
import type { JsonRpcClient } from "../rpc.js";

function mockRpc(): JsonRpcClient {
  return {
    call: vi.fn().mockResolvedValue({ success: true }),
    connect: vi.fn(),
    close: vi.fn(),
    connected: true,
  } as unknown as JsonRpcClient;
}

describe("Locator", () => {
  it("builds a single-step query path on click", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.button("OK").click();

    expect(rpc.call).toHaveBeenCalledWith("click", {
      appHandle: "h_0",
      query: [{ role: "button", title: "OK", identifier: undefined }],
      timeout: 30,
    });
  });

  it("chains multiple steps", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.window("Prefs").group("General").button("Save").click();

    expect(rpc.call).toHaveBeenCalledWith("click", {
      appHandle: "h_0",
      query: [
        { role: "window", title: "Prefs", identifier: undefined },
        { role: "group", title: "General", identifier: undefined },
        { role: "button", title: "Save", identifier: undefined },
      ],
      timeout: 30,
    });
  });

  it("locators are immutable and reusable", async () => {
    const rpc = mockRpc();
    const root = new Locator(rpc, "h_0", []);
    const window = root.window("Test");

    await window.button("A").click();
    await window.button("B").click();

    expect(rpc.call).toHaveBeenCalledTimes(2);
    const calls = (rpc.call as ReturnType<typeof vi.fn>).mock.calls;
    expect(calls[0][1].query).toHaveLength(2);
    expect(calls[1][1].query).toHaveLength(2);
    expect(calls[0][1].query[1].title).toBe("A");
    expect(calls[1][1].query[1].title).toBe("B");
  });

  it("fill sends value", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.textField("Name").fill("John");

    expect(rpc.call).toHaveBeenCalledWith("fill", {
      appHandle: "h_0",
      query: [{ role: "text_field", title: "Name", identifier: undefined }],
      value: "John",
      timeout: 30,
    });
  });

  it("waitFor sends query", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.window("New").waitFor({ timeout: 5000 });

    expect(rpc.call).toHaveBeenCalledWith("wait_for", {
      appHandle: "h_0",
      query: [{ role: "window", title: "New", identifier: undefined }],
      timeout: 5,
    });
  });

  it("locator method accepts QueryStep", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.locator({ role: "button", identifier: "save-btn" }).click();

    expect(rpc.call).toHaveBeenCalledWith("click", {
      appHandle: "h_0",
      query: [{ role: "button", identifier: "save-btn" }],
      timeout: 30,
    });
  });

  it("supports identifier-based lookups", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.button(undefined, { identifier: "ok-btn" }).click();

    expect(rpc.call).toHaveBeenCalledWith("click", {
      appHandle: "h_0",
      query: [{ role: "button", title: undefined, identifier: "ok-btn" }],
      timeout: 30,
    });
  });
});
