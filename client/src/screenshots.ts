import { randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import type { ScreenshotResult } from "./types.js";

export interface SavedScreenshot {
  path: string;
  width: number;
  height: number;
  format: "png";
}

const SCREENSHOT_DIR = join(tmpdir(), "macbeth-screenshots");

export async function saveScreenshotToTempFile(result: ScreenshotResult): Promise<SavedScreenshot> {
  await mkdir(SCREENSHOT_DIR, { recursive: true });

  const path = join(SCREENSHOT_DIR, `screenshot-${Date.now()}-${randomUUID()}.png`);
  await writeFile(path, Buffer.from(result.data, "base64"));

  return {
    path,
    width: result.width,
    height: result.height,
    format: result.format,
  };
}
