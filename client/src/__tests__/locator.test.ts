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
    }, { timeoutMs: 32_000 });
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
    }, { timeoutMs: 32_000 });
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
    }, { timeoutMs: 32_000 });
  });

  it("waitFor sends query", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.window("New").waitFor({ timeout: 5000 });

    expect(rpc.call).toHaveBeenCalledWith("wait_for", {
      appHandle: "h_0",
      query: [{ role: "window", title: "New", identifier: undefined }],
      timeout: 5,
    }, { timeoutMs: 7_000 });
  });

  it("locator method accepts QueryStep", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.locator({ role: "button", identifier: "save-btn" }).click();

    expect(rpc.call).toHaveBeenCalledWith("click", {
      appHandle: "h_0",
      query: [{ role: "button", identifier: "save-btn" }],
      timeout: 30,
    }, { timeoutMs: 32_000 });
  });

  it("supports identifier-based lookups", async () => {
    const rpc = mockRpc();
    const loc = new Locator(rpc, "h_0", []);
    await loc.button(undefined, { identifier: "ok-btn" }).click();

    expect(rpc.call).toHaveBeenCalledWith("click", {
      appHandle: "h_0",
      query: [{ role: "button", title: undefined, identifier: "ok-btn" }],
      timeout: 30,
    }, { timeoutMs: 32_000 });
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
    }, { timeoutMs: 32_000 });
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
      "get_element", "pin_handle",   // rediscover — previous handle now ages out on its own
      "click",                       // retry
    ]);
    expect(calls.at(-1)?.[1]).toMatchObject({ handleId: "h_2" });
  });

  it("does not retry a second stale failure — it fails fast instead of recursing forever", async () => {
    let nextHandle = 1;
    const rpc = mockRpc((method) => {
      if (method === "get_element") {
        return { handleId: `h_${nextHandle++}`, role: "button", enabled: true, focused: false };
      }
      if (method === "click") {
        throw new JsonRpcError(
          RPC_ERROR_CODES.staleHandle,
          "Handle is no longer usable (stale-element, reason: recycled).",
          { reason: "recycled" }
        );
      }
      return { success: true };
    });
    const scoped = await new Locator(rpc, "h_0", []).button("Save").scope();

    await expect(scoped.click()).rejects.toThrow("no longer usable");

    const methods = (rpc.call as ReturnType<typeof vi.fn>).mock.calls.map((c) => c[0]);
    // Exactly one retry: scope() + first click + one rediscover + retry click. An app
    // that keeps recycling the element faster than we can resolve it must not hang the
    // caller in unbounded recursion.
    expect(methods).toEqual(["get_element", "pin_handle", "click", "get_element", "pin_handle", "click"]);
  });

  /**
   * A daemon that restarts partway through: afterwards it has never heard of the old
   * element handle *or* the old app handle, and only a fresh connect_app produces ids it
   * will honour. This is what actually breaks a scoped locator across a restart — the
   * query path alone is not enough to recover.
   */
  function restartingDaemon() {
    let restarted = false;
    let nextHandle = 1;
    const rpc = mockRpc((method, params) => {
      const p = (params ?? {}) as { appHandle?: string; handleId?: string };

      if (method === "connect_app") {
        restarted = false;
        return { appHandle: "app_2", name: "Notes", pid: 77, bundleId: null };
      }
      if (restarted) {
        // Mirrors the daemon's own checking order: actions resolve handleId before
        // touching the app handle, while query-based lookups validate the app first.
        const unknownHandle = new JsonRpcError(
          RPC_ERROR_CODES.unknownHandle,
          `Unknown handle ${p.handleId}: this daemon never issued it.`,
          { reason: "never_issued", handleId: p.handleId }
        );
        const actionResolvesHandleFirst = method === "click" || method === "fill";
        if (actionResolvesHandleFirst && p.handleId !== undefined) throw unknownHandle;
        if (p.appHandle === "app_1") {
          throw new JsonRpcError(RPC_ERROR_CODES.appNotFound, "Invalid app handle: app_1");
        }
        if (p.handleId !== undefined) throw unknownHandle;
      }
      if (method === "get_element") {
        return { handleId: `h_${nextHandle++}`, role: "button", enabled: true, focused: false };
      }
      return { success: true };
    });
    return { rpc, restart: () => { restarted = true; } };
  }

  it("scoped locators re-acquire the app handle after a daemon restart", async () => {
    const { rpc, restart } = restartingDaemon();
    const reacquireApp = async () => {
      const result = await rpc.call<{ appHandle: string }>("connect_app", { pid: 77 });
      return result.appHandle;
    };
    const scoped = await new Locator(rpc, "app_1", [], { reacquireApp })
      .button("Save").scope();

    restart();
    await scoped.click();

    const calls = (rpc.call as ReturnType<typeof vi.fn>).mock.calls;
    expect(calls.map((c) => c[0])).toEqual([
      "get_element", "pin_handle",   // scope(), pre-restart
      "click",                       // fails: unknown_handle
      "connect_app",                 // the old app handle is dead too
      "get_element", "pin_handle",   // replay the query against the new app root
      "click",                       // retry
    ]);
    // Both ids are refreshed — replaying the query against the stale app handle would
    // have failed, or worse, resolved against whatever app now owns that id.
    expect(calls.at(-1)?.[1]).toMatchObject({ appHandle: "app_2", handleId: "h_2" });
  });

  it("scoped locators re-acquire the app handle when the query is rejected for it", async () => {
    // Some paths report the element handle as stale first and only reject the app handle
    // on the follow-up query. Recovery has to notice that and reconnect too.
    let appHandleValid = false;
    let nextHandle = 1;
    let clicks = 0;
    const rpc = mockRpc((method, params) => {
      const p = (params ?? {}) as { appHandle?: string; handleId?: string };
      if (method === "connect_app") {
        appHandleValid = true;
        return { appHandle: "app_2" };
      }
      if (method === "click" && clicks++ === 0) {
        throw new JsonRpcError(
          RPC_ERROR_CODES.staleHandle,
          "Handle h_1 is no longer usable (stale-element, reason: destroyed).",
          { reason: "destroyed", handleId: "h_1" }
        );
      }
      if (!appHandleValid && p.appHandle === "app_1") {
        throw new JsonRpcError(RPC_ERROR_CODES.appNotFound, "Invalid app handle: app_1");
      }
      if (method === "get_element") {
        return { handleId: `h_${nextHandle++}`, role: "button", enabled: true, focused: false };
      }
      return { success: true };
    });

    appHandleValid = true;   // healthy while the locator is being scoped
    const scoped = await new Locator(rpc, "app_1", [], {
      reacquireApp: async () =>
        (await rpc.call<{ appHandle: string }>("connect_app", { pid: 77 })).appHandle,
    }).button("Save").scope();
    appHandleValid = false;  // the app handle dies before the first action

    await scoped.click();

    const calls = (rpc.call as ReturnType<typeof vi.fn>).mock.calls;
    expect(calls.map((c) => c[0])).toEqual([
      "get_element", "pin_handle",
      "click",                       // fails: stale handle
      "get_element",                 // replay rejected: app handle is gone
      "connect_app",
      "get_element", "pin_handle",   // replay against the new app root
      "click",
    ]);
    expect(calls.at(-1)?.[1]).toMatchObject({ appHandle: "app_2" });
  });

  it("does not reacquire the app handle twice within one rediscovery", async () => {
    // unknown_handle already triggers a reacquire up front. If the replayed query is
    // rejected too, reconnecting again would not help — it would just waste a redundant
    // connect_app (which waits for Electron web content on every call).
    let clicks = 0;
    let getElementCalls = 0;
    const rpc = mockRpc((method) => {
      if (method === "get_element") {
        getElementCalls++;
        if (getElementCalls === 1) {
          return { handleId: "h_1", role: "button", enabled: true, focused: false };
        }
        throw new JsonRpcError(RPC_ERROR_CODES.appNotFound, "Invalid app handle: app_2");
      }
      if (method === "click" && clicks++ === 0) {
        throw new JsonRpcError(
          RPC_ERROR_CODES.unknownHandle,
          "Unknown handle h_1: this daemon never issued it.",
          { reason: "never_issued", handleId: "h_1" }
        );
      }
      return { success: true };
    });
    const reacquireApp = async () =>
      (await rpc.call<{ appHandle: string }>("connect_app", { pid: 77 })).appHandle;
    const scoped = await new Locator(rpc, "app_1", [], { reacquireApp }).button("Save").scope();

    await expect(scoped.click()).rejects.toThrow("Invalid app handle");

    const methods = (rpc.call as ReturnType<typeof vi.fn>).mock.calls.map((c) => c[0]);
    expect(methods.filter((m) => m === "connect_app")).toHaveLength(1);
  });

  it("does not reconnect on an ordinary TTL re-resolve", async () => {
    // connect_app waits for Electron web content to build, so it must stay off the path
    // of a routine expiry recovery.
    const { rpc, scoped } = await scopedLocatorFailingOnce(
      new JsonRpcError(
        RPC_ERROR_CODES.staleHandle,
        "Handle h_1 is no longer usable (stale-element, reason: expired).",
        { reason: "expired", handleId: "h_1" }
      )
    );

    await scoped.click();

    const methods = (rpc.call as ReturnType<typeof vi.fn>).mock.calls.map((c) => c[0]);
    expect(methods).not.toContain("connect_app");
  });

  it("scoped locators do not retry errors that re-resolving cannot fix", async () => {
    const { scoped } = await scopedLocatorFailingOnce(
      new JsonRpcError(RPC_ERROR_CODES.actionFailed, "AXPress unsupported on the element.")
    );

    await expect(scoped.click()).rejects.toThrow("AXPress unsupported");
  });
});
