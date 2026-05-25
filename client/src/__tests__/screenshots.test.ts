import { readFile, stat } from "node:fs/promises";
import { basename } from "node:path";
import { describe, expect, it } from "vitest";

import { saveScreenshotToTempFile } from "../screenshots.js";

describe("saveScreenshotToTempFile", () => {
  it("writes the PNG bytes to a temp file and returns its metadata", async () => {
    const pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aBW0AAAAASUVORK5CYII=";

    const saved = await saveScreenshotToTempFile({
      data: pngBase64,
      width: 1,
      height: 1,
      format: "png",
    });

    expect(saved.width).toBe(1);
    expect(saved.height).toBe(1);
    expect(saved.format).toBe("png");
    expect(basename(saved.path)).toMatch(/^screenshot-\d+-[\w-]+\.png$/);

    const [info, bytes] = await Promise.all([
      stat(saved.path),
      readFile(saved.path),
    ]);

    expect(info.isFile()).toBe(true);
    expect(bytes.toString("base64")).toBe(pngBase64);
  });
});
