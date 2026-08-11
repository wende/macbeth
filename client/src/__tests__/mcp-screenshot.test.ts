import { describe, expect, it, vi } from "vitest";
import { parse as parseYaml } from "yaml";

import { runScreenshotTool } from "../mcp-screenshot.js";

describe("runScreenshotTool", () => {
  it("captures a screenshot, saves it, and returns the saved path payload", async () => {
    const screenshotRaw = vi.fn().mockResolvedValue({
      data: "base64-png",
      width: 640,
      height: 480,
      format: "png",
    });
    const connect = vi.fn().mockResolvedValue({ screenshotRaw });
    const save = vi.fn().mockResolvedValue({
      path: "/tmp/macbeth-screenshots/screenshot-123.png",
      width: 640,
      height: 480,
      format: "png",
    });

    const result = await runScreenshotTool(
      { connect, save },
      {
        app: "Finder",
        windowId: 99,
        region: { x: 1, y: 2, width: 3, height: 4 },
      }
    );

    expect(connect).toHaveBeenCalledWith("Finder");
    expect(screenshotRaw).toHaveBeenCalledWith({
      windowId: 99,
      region: { x: 1, y: 2, width: 3, height: 4 },
    });
    expect(save).toHaveBeenCalledWith({
      data: "base64-png",
      width: 640,
      height: 480,
      format: "png",
    });
    expect(result.content[0].type).toBe("text");
    const parsed = parseYaml(result.content[0].text) as {
      path: string;
      width: number;
      height: number;
      format: string;
    };
    expect(parsed).toEqual({
      path: "/tmp/macbeth-screenshots/screenshot-123.png",
      width: 640,
      height: 480,
      format: "png",
    });
  });

  it("accepts a numeric PID app target", async () => {
    const screenshotRaw = vi.fn().mockResolvedValue({
      data: "base64-png",
      width: 1,
      height: 1,
      format: "png",
    });
    const connect = vi.fn().mockResolvedValue({ screenshotRaw });
    const save = vi.fn().mockResolvedValue({ path: "/tmp/screenshot.png", width: 1, height: 1, format: "png" });

    await runScreenshotTool({ connect, save }, { app: 4242 });

    expect(connect).toHaveBeenCalledWith(4242);
  });
});
