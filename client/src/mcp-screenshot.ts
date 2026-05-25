import type { ScreenshotResult } from "./types.js";
import type { SavedScreenshot } from "./screenshots.js";

type ScreenshotRegion = {
  x: number;
  y: number;
  width: number;
  height: number;
};

interface ScreenshotHandle {
  screenshotRaw(options?: { region?: ScreenshotRegion }): Promise<ScreenshotResult>;
}

interface ScreenshotDeps {
  connect: (app: string) => Promise<ScreenshotHandle>;
  save: (result: ScreenshotResult) => Promise<SavedScreenshot>;
}

export async function runScreenshotTool(
  deps: ScreenshotDeps,
  params: { app: string; region?: ScreenshotRegion }
) {
  const handle = await deps.connect(params.app);
  const saved = await deps.save(
    await handle.screenshotRaw({ region: params.region ?? undefined })
  );

  return {
    content: [{
      type: "text" as const,
      text: JSON.stringify(saved, null, 2),
    }],
  };
}
