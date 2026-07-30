import type { ScreenshotResult } from "./types.js";
import type { SavedScreenshot } from "./screenshots.js";

type ScreenshotRegion = {
  x: number;
  y: number;
  width: number;
  height: number;
};

interface ScreenshotHandle {
  screenshotRaw(options?: { windowId?: number; region?: ScreenshotRegion }): Promise<ScreenshotResult>;
}

interface ScreenshotDeps {
  connect: (app: string | number) => Promise<ScreenshotHandle>;
  save: (result: ScreenshotResult) => Promise<SavedScreenshot>;
}

export async function runScreenshotTool(
  deps: ScreenshotDeps,
  params: { app: string | number; windowId?: number; region?: ScreenshotRegion }
) {
  const handle = await deps.connect(params.app);
  const saved = await deps.save(
    await handle.screenshotRaw({
      windowId: params.windowId,
      region: params.region ?? undefined,
    })
  );

  return {
    content: [{
      type: "text" as const,
      text: JSON.stringify(saved, null, 2),
    }],
  };
}
