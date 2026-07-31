import { describe, expect, it, vi } from "vitest";
import { appConnectParams, formatAppList, isAppHandle } from "../app-target.js";
import { MacbethClient } from "../client.js";
import type { AppAccessibility, AppInfo } from "../types.js";

const CONNECTABLE: AppAccessibility = { status: "connectable", connectable: true };

const NOT_CONNECTABLE: AppAccessibility = {
  status: "not_connectable",
  connectable: false,
  axCode: -25204,
  axError: "cannot_complete",
  explanation: "The process did not answer the accessibility request.",
  nextAction: "Fall back to screenshot + extract_text.",
};

const PERMISSION_REQUIRED: AppAccessibility = {
  status: "permission_required",
  connectable: false,
  axCode: -25211,
  axError: "api_disabled",
  explanation: "Accessibility permission has not been granted.",
  nextAction: "Grant Accessibility under System Settings → Privacy & Security.",
};

function app(name: string, pid: number, accessibility: AppAccessibility): AppInfo {
  return {
    name,
    pid,
    bundleId: `com.example.${name.toLowerCase().replace(/\s+/g, "")}`,
    aliases: [],
    runtime: "native",
    accessibility,
  };
}

describe("isAppHandle", () => {
  it("recognises daemon-minted handles", () => {
    expect(isAppHandle("h_0")).toBe(true);
    expect(isAppHandle("h_369")).toBe(true);
  });

  it("does not mistake app names or PIDs for handles", () => {
    expect(isAppHandle("Finder")).toBe(false);
    expect(isAppHandle("h_")).toBe(false);
    expect(isAppHandle("h_3x")).toBe(false);
    expect(isAppHandle("Handbrake")).toBe(false);
    expect(isAppHandle(369)).toBe(false);
  });
});

describe("appConnectParams", () => {
  it("routes names, PIDs, and handles to distinct params", () => {
    expect(appConnectParams("Finder")).toEqual({ name: "Finder" });
    expect(appConnectParams(1234)).toEqual({ pid: 1234 });
    expect(appConnectParams("h_369")).toEqual({ appHandle: "h_369" });
  });
});

describe("MacbethClient.connect", () => {
  function clientWithFakeRpc(): { client: MacbethClient; call: ReturnType<typeof vi.fn> } {
    // daemonPath short-circuits binary discovery; nothing is ever spawned here.
    const client = new MacbethClient({ daemonPath: "/nonexistent/macbethd" });
    const call = vi.fn().mockResolvedValue({
      appHandle: "h_369",
      name: "Unity",
      pid: 42,
      bundleId: "com.unity3d.unity",
    });
    // Bypass daemon spawning; only the outgoing params matter here.
    (client as unknown as { ensureConnected: () => Promise<void> }).ensureConnected =
      async () => {};
    (client as unknown as { rpc: { call: typeof call } }).rpc = { call };
    return { client, call };
  }

  it("reuses a connection when handed back the handle connect_app returned", async () => {
    const { client, call } = clientWithFakeRpc();
    await client.connect("h_369");
    expect(call).toHaveBeenCalledWith("connect_app", { appHandle: "h_369" });
  });

  it("still resolves plain names by name", async () => {
    const { client, call } = clientWithFakeRpc();
    await client.connect("Unity", { readyTimeoutMs: 5000 });
    expect(call).toHaveBeenCalledWith("connect_app", { name: "Unity", readyTimeoutMs: 5000 });
  });
});

describe("formatAppList", () => {
  it("separates connectable apps from running-but-not-connectable ones", () => {
    const text = formatAppList([
      app("Finder", 100, CONNECTABLE),
      app("Unity Hub", 200, NOT_CONNECTABLE),
    ]);

    expect(text).toContain("Connectable through Accessibility (1):");
    expect(text).toMatch(/Finder \(pid: 100/);
    expect(text).toContain("Running but NOT connectable through Accessibility (1)");
    expect(text).toContain("connect_app will fail for these");
    expect(text).toMatch(/Unity Hub \(pid: 200/);
  });

  it("explains an AX failure with its code and a next action", () => {
    const text = formatAppList([app("Unity Hub", 200, NOT_CONNECTABLE)]);

    expect(text).toContain("[AX -25204 cannot_complete]");
    expect(text).toContain("did not answer the accessibility request");
    expect(text).toContain("Next: Fall back to screenshot + extract_text.");
  });

  it("keeps a not-connectable app out of the connectable section", () => {
    const text = formatAppList([app("Unity Hub", 200, NOT_CONNECTABLE)]);

    expect(text).toContain("Connectable through Accessibility: none.");
    const blockedAt = text.indexOf("Running but NOT connectable");
    expect(blockedAt).toBeGreaterThan(-1);
    expect(text.indexOf("Unity Hub")).toBeGreaterThan(blockedAt);
  });

  it("omits the failure section when everything is connectable", () => {
    const text = formatAppList([app("Finder", 100, CONNECTABLE)]);

    expect(text).toContain("Connectable through Accessibility (1):");
    expect(text).not.toContain("NOT connectable");
  });

  it("reports a missing-permission blockade once instead of per app", () => {
    const text = formatAppList([
      app("Finder", 100, PERMISSION_REQUIRED),
      app("Safari", 101, PERMISSION_REQUIRED),
    ]);

    expect(text).toContain("No app is reachable through Accessibility right now");
    expect(text).toContain("AX -25211 api_disabled");
    expect(text).toContain("Next: Grant Accessibility");
    expect(text.match(/api_disabled/g)).toHaveLength(1);
    expect(text).toContain("Finder");
    expect(text).toContain("Safari");
  });

  it("handles an empty list", () => {
    expect(formatAppList([])).toBe("No running apps found.");
  });

  it("lists apps flat when the daemon is too old to report readiness", () => {
    // Pre-probing daemons omit the field entirely. Everything should still list
    // rather than being declared unreachable.
    const legacy = { name: "Finder", pid: 100, bundleId: null, aliases: [], runtime: "native" };
    const text = formatAppList([legacy as unknown as AppInfo]);

    expect(text).toContain("Connectable through Accessibility (1):");
    expect(text).toContain("Finder (pid: 100");
    expect(text).not.toContain("NOT connectable");
  });
});
