import { describe, expect, it, vi } from "vitest";

import { runPinHandleTool, type PinHandleResult } from "../mcp-pin.js";

const deps = (result?: PinHandleResult) => ({
  pinHandle: vi.fn().mockResolvedValue(result ?? { pinned: true as const, handleId: "h_1" }),
});

const text = (r: { content: Array<{ text: string }> }) => r.content[0].text;

describe("runPinHandleTool", () => {
  it("rejects a request with neither handleId nor handleIds", async () => {
    const d = deps();
    const result = await runPinHandleTool(d, {});
    expect(result.isError).toBe(true);
    expect(d.pinHandle).not.toHaveBeenCalled();
  });

  it("rejects an empty handleIds array instead of round-tripping a no-op", async () => {
    const d = deps();
    const result = await runPinHandleTool(d, { handleIds: [] });
    expect(result.isError).toBe(true);
    expect(text(result)).toMatch(/non-empty/);
    expect(d.pinHandle).not.toHaveBeenCalled();
  });

  it("rejects handleId and handleIds together", async () => {
    const d = deps();
    const result = await runPinHandleTool(d, { handleId: "h_1", handleIds: ["h_2"] });
    expect(result.isError).toBe(true);
    expect(d.pinHandle).not.toHaveBeenCalled();
  });

  it("reports the singular path", async () => {
    const d = deps();
    const result = await runPinHandleTool(d, { handleId: "h_1" });
    expect(d.pinHandle).toHaveBeenCalledWith("h_1");
    expect(result.isError).toBeUndefined();
    expect(text(result)).toBe("Pinned handle: h_1");
  });

  it("renders a mixed batch per id and does not flag it as an error", async () => {
    const d = deps({
      results: { h_1: true, h_2: { error: "unknown_handle" } },
    });
    const result = await runPinHandleTool(d, { handleIds: ["h_1", "h_2"] });
    expect(d.pinHandle).toHaveBeenCalledWith(["h_1", "h_2"]);
    expect(text(result)).toBe("h_1: pinned\nh_2: unknown_handle");
    expect(result.isError).toBe(false);
  });

  it("flags a batch where nothing pinned as an error", async () => {
    const d = deps({
      results: { h_9: { error: "unknown_handle" }, h_8: { error: "stale_handle: expired" } },
    });
    const result = await runPinHandleTool(d, { handleIds: ["h_9", "h_8"] });
    expect(result.isError).toBe(true);
  });
});
