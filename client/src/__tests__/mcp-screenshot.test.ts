import { describe, expect, it, vi } from "vitest";

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
        region: { x: 1, y: 2, width: 3, height: 4 },
      }
    );

    expect(connect).toHaveBeenCalledWith("Finder");
    expect(screenshotRaw).toHaveBeenCalledWith({
      region: { x: 1, y: 2, width: 3, height: 4 },
    });
    expect(save).toHaveBeenCalledWith({
      data: "base64-png",
      width: 640,
      height: 480,
      format: "png",
    });
    expect(result).toEqual({
      content: [{
        type: "text",
        text: JSON.stringify({
          path: "/tmp/macbeth-screenshots/screenshot-123.png",
          width: 640,
          height: 480,
          format: "png",
        }, null, 2),
      }],
    });
  });
});
