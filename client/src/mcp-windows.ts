import type { AppTarget } from "./app-target.js";
import type { AppWindowInfo, ListWindowsOptions } from "./types.js";
import { toModelPayload } from "./mcp-format.js";

interface WindowLister {
  listWindows(options?: ListWindowsOptions): Promise<AppWindowInfo[]>;
}

interface ListWindowsDeps {
  /** Scoped listing: connect to the requested app first. */
  connect: (app: AppTarget) => Promise<WindowLister>;
  /** Unscoped listing: every app that owns a window. */
  listAll: WindowLister["listWindows"];
}

export interface ListWindowsToolParams {
  app?: AppTarget;
  includeAllSurfaces?: boolean;
  titlePattern?: string;
}

/**
 * `list_windows` tool body. Keeping the app filter optional is the point: an
 * agent asking "is a Unity window open?" gets an answer in one call, without
 * connecting to an app or paying for an accessibility-tree walk.
 */
export async function runListWindowsTool(
  deps: ListWindowsDeps,
  params: ListWindowsToolParams
) {
  const options: ListWindowsOptions = {
    ...(params.includeAllSurfaces ? { includeAllSurfaces: true } : {}),
    ...(params.titlePattern ? { titlePattern: params.titlePattern } : {}),
  };
  const windows = params.app === undefined
    ? await deps.listAll(options)
    : await (await deps.connect(params.app)).listWindows(options);

  return {
    content: [{
      type: "text" as const,
      text: toModelPayload({ count: windows.length, windows }),
    }],
  };
}
