import { describe, expect, it, vi } from "vitest";

import { runListWindowsTool } from "../mcp-windows.js";
import type { AppWindowInfo } from "../types.js";

function windowInfo(overrides: Partial<AppWindowInfo> = {}): AppWindowInfo {
  return {
    windowId: 42,
    ownerPid: 501,
    ownerName: "Unity",
    bundleId: "com.unity3d.UnityEditor",
    title: "SampleScene",
    frame: { x: 0, y: 0, width: 1200, height: 800 },
    layer: 0,
    onScreen: true,
    active: true,
    capturable: true,
    kind: "window",
    default: true,
    role: "AXWindow",
    subrole: "AXStandardWindow",
    minimized: false,
    ...overrides,
  };
}

function payload(result: Awaited<ReturnType<typeof runListWindowsTool>>) {
  return JSON.parse(result.content[0].text) as { count: number; windows: AppWindowInfo[] };
}

describe("runListWindowsTool", () => {
  it("lists windows for every app when no app filter is given", async () => {
    const windows = [
      windowInfo(),
      windowInfo({ windowId: 7, ownerPid: 502, ownerName: "Finder", bundleId: "com.apple.finder", title: "Documents" }),
    ];
    const listAll = vi.fn().mockResolvedValue(windows);
    const connect = vi.fn();

    const result = await runListWindowsTool({ connect, listAll }, {});

    expect(connect).not.toHaveBeenCalled();
    expect(listAll).toHaveBeenCalledWith(undefined);
    expect(payload(result)).toEqual({ count: 2, windows });
  });

  it("scopes the listing to one app when an app filter is given", async () => {
    const windows = [windowInfo()];
    const listWindows = vi.fn().mockResolvedValue(windows);
    const connect = vi.fn().mockResolvedValue({ listWindows });
    const listAll = vi.fn();

    const result = await runListWindowsTool({ connect, listAll }, { app: "Unity" });

    expect(connect).toHaveBeenCalledWith("Unity");
    expect(listWindows).toHaveBeenCalledWith(undefined);
    expect(listAll).not.toHaveBeenCalled();
    expect(payload(result)).toEqual({ count: 1, windows });
  });

  it("accepts a numeric PID app filter", async () => {
    const listWindows = vi.fn().mockResolvedValue([]);
    const connect = vi.fn().mockResolvedValue({ listWindows });

    await runListWindowsTool({ connect, listAll: vi.fn() }, { app: 4321 });

    expect(connect).toHaveBeenCalledWith(4321);
  });

  it("reports an empty listing when nothing has a window", async () => {
    const listAll = vi.fn().mockResolvedValue([]);

    const result = await runListWindowsTool({ connect: vi.fn(), listAll }, {});

    expect(payload(result)).toEqual({ count: 0, windows: [] });
  });

  it("forwards includeAllSurfaces to both listing paths", async () => {
    const listAll = vi.fn().mockResolvedValue([]);
    const listWindows = vi.fn().mockResolvedValue([]);
    const connect = vi.fn().mockResolvedValue({ listWindows });

    await runListWindowsTool({ connect, listAll }, { includeAllSurfaces: true });
    await runListWindowsTool({ connect, listAll }, { app: "Unity", includeAllSurfaces: true });

    expect(listAll).toHaveBeenCalledWith({ includeAllSurfaces: true });
    expect(listWindows).toHaveBeenCalledWith({ includeAllSurfaces: true });
  });
});
