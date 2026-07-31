import { describe, it, expect, vi } from "vitest";
import { Locator } from "../elements.js";
import { JsonRpcError, RPC_ERROR_CODES } from "../errors.js";
import type { JsonRpcClient } from "../rpc.js";

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

  it("forwards mouse strategy and idle protection", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.button("Canvas").click({ strategy: "mouse", waitForIdleMs: 500 });

    expect(rpc.call).toHaveBeenCalledWith("click", {
      appHandle: "h_0",
      query: [{ role: "button", title: "Canvas", identifier: undefined }],
      timeout: 30,
      strategy: "mouse",
      waitForIdleMs: 500,
    });
  });

  it("omits idle protection when only the mouse strategy is requested", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.button("Canvas").click({ strategy: "mouse" });

    const payload = (rpc.call as ReturnType<typeof vi.fn>).mock.calls[0][1];
    expect(payload).toMatchObject({ strategy: "mouse" });
    expect(payload).not.toHaveProperty("waitForIdleMs");
  });

  it("scoped locators forward and omit idle protection correctly", async () => {
    const rpc = mockRpc((method) => {
      if (method === "get_element") {
        return { handleId: "h_1", role: "button", enabled: true, focused: false };
      }
      return { success: true };
    });
    const scoped = await new Locator(rpc, "h_0", []).button("Canvas").scope();
    const calls = rpc.call as ReturnType<typeof vi.fn>;

    await scoped.click({ strategy: "mouse", waitForIdleMs: 500 });
    expect(calls.mock.calls.at(-1)?.[1]).toMatchObject({
      handleId: "h_1",
      strategy: "mouse",
      waitForIdleMs: 500,
    });

    await scoped.click({ strategy: "mouse" });
    const payload = calls.mock.calls.at(-1)?.[1];
    expect(payload).toMatchObject({ handleId: "h_1", strategy: "mouse" });
    expect(payload).not.toHaveProperty("waitForIdleMs");
  });

  /** Builds a scoped locator whose first click fails with `err`, then succeeds. */
  async function scopedLocatorFailingOnce(err: unknown) {
    const handles = ["h_1", "h_2"];
    let clicks = 0;
    const rpc = mockRpc((method) => {
      if (method === "get_element") {
        return { handleId: handles.shift(), role: "button", enabled: true, focused: false };
      }
      if (method === "click" && clicks++ === 0) throw err;
      return { success: true };
    });
    const scoped = await new Locator(rpc, "h_0", []).button("Save").scope();
    return { rpc, scoped };
  }

  it("scoped locators re-resolve when the daemon retires their handle", async () => {
    const { rpc, scoped } = await scopedLocatorFailingOnce(
      new JsonRpcError(
        RPC_ERROR_CODES.staleHandle,
        "Handle h_1 is no longer usable (stale-element, reason: recycled).",
        { reason: "recycled", handleId: "h_1" }
      )
    );

    await scoped.click();

    const calls = (rpc.call as ReturnType<typeof vi.fn>).mock.calls;
    expect(calls.map((c) => c[0])).toEqual([
      "get_element", "pin_handle",   // scope()
      "click",                       // fails: stale handle
      "get_element", "pin_handle",   // rediscover
      "click",                       // retry
    ]);
    expect(calls.at(-1)?.[1]).toMatchObject({ handleId: "h_2" });
  });

  it("scoped locators re-resolve after a daemon restart drops their handle", async () => {
    // A restarted daemon has never issued the old id, so it answers unknown_handle
    // rather than stale — still recoverable, because the locator kept its query path.
    const { rpc, scoped } = await scopedLocatorFailingOnce(
      new JsonRpcError(
        RPC_ERROR_CODES.unknownHandle,
        "Unknown handle h_1: this daemon never issued it.",
        { reason: "never_issued", handleId: "h_1" }
      )
    );

    await scoped.click();

    const calls = (rpc.call as ReturnType<typeof vi.fn>).mock.calls;
    expect(calls.at(-1)?.[0]).toBe("click");
    expect(calls.at(-1)?.[1]).toMatchObject({ handleId: "h_2" });
  });

  it("scoped locators do not retry errors that re-resolving cannot fix", async () => {
    const { scoped } = await scopedLocatorFailingOnce(
      new JsonRpcError(RPC_ERROR_CODES.actionFailed, "AXPress unsupported on the element.")
    );

    await expect(scoped.click()).rejects.toThrow("AXPress unsupported");
  });
});
