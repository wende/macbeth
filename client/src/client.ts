import { DaemonManager } from "./daemon.js";
import { JsonRpcClient } from "./rpc.js";
import { Locator } from "./elements.js";
import { appConnectParams, type AppTarget } from "./app-target.js";
import type { HealthSnapshot } from "./health.js";
import {
  actionRequestTimeoutMs,
  actionTimeoutFromSeconds,
  clampScriptTimeoutMs,
  scriptRequestTimeoutMs,
  SCRIPT_TIMEOUT,
} from "./timeouts.js";
import type {
  ConnectOptions,
  AppConnectOptions,
  AppInfo,
  AppRuntime,
  KeyStroke,
  PressKeyResult,
  PressKeysResult,
  TreeOptions,
  ScreenshotResult,
  QueryStep,
  ElementTarget,
  ElementInfo,
  ClickStrategy,
  FillStrategy,
  FormField,
  AppMatchKind,
  QueryTreeDetailedResult,
  TreeDiagnostics,
  AppWindowInfo,
  ListWindowsOptions,
  ListMenuBarOptions,
} from "./types.js";

/**
 * AppHandle represents a connected application.
 * Extends Locator so the app itself is the root — you can chain directly:
 *   app.window('X').button('Y').click()
 */
export class AppHandle extends Locator {
  readonly name: string;
  readonly pid: number;
  readonly bundleId: string | null;
  readonly aliases: string[];
  readonly runtime: AppRuntime;
  readonly requestedName: string | null;
  readonly matchKind: AppMatchKind;
  readonly matchedValue: string;
  readonly manualAccessibility: string;
  readonly webContentReadiness: TreeDiagnostics["webContent"] | null;

  constructor(
    rpc: JsonRpcClient,
    appHandle: string,
    info: {
      name: string;
      pid: number;
      bundleId: string | null;
      aliases?: string[];
      runtime?: AppRuntime;
      requestedName?: string | null;
      matchKind?: AppMatchKind;
      matchedValue?: string;
      manualAccessibility?: string;
      webContentReadiness?: TreeDiagnostics["webContent"] | null;
    },
    options?: { timeout?: number }
  ) {
    super(rpc, appHandle, [], options);
    this.name = info.name;
    this.pid = info.pid;
    this.bundleId = info.bundleId;
    this.aliases = info.aliases ?? [];
    this.runtime = info.runtime ?? "unknown";
    this.requestedName = info.requestedName ?? null;
    this.matchKind = info.matchKind ?? "pid";
    this.matchedValue = info.matchedValue ?? String(info.pid);
    this.manualAccessibility = info.manualAccessibility ?? "unknown";
    this.webContentReadiness = info.webContentReadiness ?? null;
    this.reacquireApp = () => this.reconnect();
  }

  /** Opaque app handle used by subsequent RPC calls. */
  get handle(): string {
    return this.appHandle;
  }

  /**
   * Re-connect to this app and adopt its current app handle.
   *
   * App handles are daemon-local: a daemon restart invalidates them, and the new process
   * may hand the same `h_N` to whichever app connects first. Re-connecting by pid pins
   * this handle back to the right app. Scoped locators derived from this AppHandle call
   * it when a recovery needs it — see `Locator.rediscover`.
   *
   * Throws `app_not_found` if the app itself is gone (a relaunch changes the pid, so the
   * caller has to connect again by name).
   */
  async reconnect(): Promise<string> {
    const result = await this.rpc.call<{ appHandle: string }>("connect_app", {
      pid: this.pid,
    });
    this.appHandle = result.appHandle;
    return result.appHandle;
  }

  /** Get the AX tree as indented text or JSON */
  async queryTree(options?: TreeOptions): Promise<string> {
    return (await this.queryTreeDetailed(options)).tree;
  }

  /** Get the AX tree together with runtime/readiness diagnostics. */
  async queryTreeDetailed(options?: TreeOptions): Promise<QueryTreeDetailedResult> {
    const result = await this.rpc.call<{
      tree: string | object;
      diagnostics?: TreeDiagnostics;
    }>("query_tree", {
      appHandle: this.appHandle,
      ...(options?.handleId !== undefined ? { handleId: options.handleId } : {}),
      maxDepth: options?.maxDepth ?? 5,
      ...(options?.maxNodes !== undefined ? { maxNodes: options.maxNodes } : {}),
      format: options?.format ?? "text",
      includeInvisible: options?.includeInvisible ?? false,
      ...(options?.pin ? { pin: true } : {}),
    });
    return {
      tree: typeof result.tree === "string"
        ? result.tree
        : JSON.stringify(result.tree, null, 2),
      diagnostics: result.diagnostics ?? {
        runtime: this.runtime,
        webContent: this.webContentReadiness ?? "no_web_area",
      },
    };
  }

  /** List WindowServer surfaces owned by the app or its helper processes.
   *  Returns real windows only unless `includeAllSurfaces` is set. */
  async listWindows(options?: ListWindowsOptions): Promise<AppWindowInfo[]> {
    const result = await this.rpc.call<{ windows: AppWindowInfo[] }>("list_windows", {
      appHandle: this.appHandle,
      ...(options?.includeAllSurfaces ? { includeAllSurfaces: true } : {}),
      ...(options?.titlePattern ? { titlePattern: options.titlePattern } : {}),
    });
    return result.windows;
  }

  /** Capture a screenshot of the app window, optionally cropped to a region */
  async screenshot(options?: { windowId?: number; region?: { x: number; y: number; width: number; height: number } }): Promise<Buffer> {
    const result = await this.rpc.call<ScreenshotResult>("screenshot", {
      appHandle: this.appHandle,
      ...(options?.windowId !== undefined ? { windowId: options.windowId } : {}),
      ...(options?.region ? { region: options.region } : {}),
    });
    return Buffer.from(result.data, "base64");
  }

  /** Capture a screenshot and return the raw RPC result (base64 + dimensions) */
  async screenshotRaw(options?: { windowId?: number; region?: { x: number; y: number; width: number; height: number } }): Promise<ScreenshotResult> {
    return this.rpc.call<ScreenshotResult>("screenshot", {
      appHandle: this.appHandle,
      ...(options?.windowId !== undefined ? { windowId: options.windowId } : {}),
      ...(options?.region ? { region: options.region } : {}),
    });
  }

  /** Read form-like controls (text fields, sliders, checkboxes, etc.) from a subtree */
  async readForm(options?: { handleId?: string; query?: QueryStep[]; maxDepth?: number; pin?: boolean }): Promise<FormField[]> {
    const result = await this.rpc.call<{ fields: FormField[] }>("read_form", {
      appHandle: this.appHandle,
      ...options,
    });
    return result.fields;
  }

  /** List the native menu bar hierarchy through Accessibility. */
  async listMenuBar(options?: ListMenuBarOptions): Promise<string> {
    const result = await this.rpc.call<{ menu: string }>("list_menu_bar", {
      appHandle: this.appHandle,
      ...(options?.titlePattern ? { titlePattern: options.titlePattern } : {}),
    });
    return result.menu;
  }

  /** Select a native menu item through Accessibility. */
  async selectMenuItem(menuPath: string[]): Promise<string> {
    const result = await this.rpc.call<{ selected: string }>("select_menu_item", {
      appHandle: this.appHandle,
      menuPath,
    });
    return result.selected;
  }

  /** Send a keyboard input.
   *
   *  Resolves with what could be established about the dispatch — see
   *  {@link PressKeyResult}. It rejects only on RPC-level failures, so callers
   *  that ignore the result behave exactly as before. */
  async pressKey(
    key: string,
    modifiers?: string[]
  ): Promise<PressKeyResult> {
    return await this.rpc.call<PressKeyResult>("press_key", {
      appHandle: this.appHandle,
      key,
      modifiers,
    });
  }

  /** Send a sequence of keyboard inputs in one RPC call */
  async pressKeys(keys: KeyStroke[]): Promise<PressKeysResult> {
    return await this.rpc.call<PressKeysResult>("press_keys", {
      appHandle: this.appHandle,
      keys,
    });
  }

  /** Click an element addressed by a locator query or a direct handle id.
   *  Lower-level than {@link Locator.click}: it applies no query chain and takes
   *  `timeout` in seconds (matching the RPC). The MCP server uses this because it
   *  resolves the target itself. */
  async clickTarget(
    target: ElementTarget,
    options?: { timeout?: number; strategy?: ClickStrategy; waitForIdleMs?: number }
  ): Promise<void> {
    const timeoutMs = actionTimeoutFromSeconds(options?.timeout);
    await this.rpc.call("click", {
      appHandle: this.appHandle,
      ...target,
      timeout: timeoutMs / 1_000,
      ...(options?.strategy ? { strategy: options.strategy } : {}),
      ...(options?.waitForIdleMs !== undefined ? { waitForIdleMs: options.waitForIdleMs } : {}),
    }, { timeoutMs: actionRequestTimeoutMs(timeoutMs) });
  }

  /** Fill an element addressed by a locator query or a direct handle id.
   *  `timeout` is in seconds. See {@link clickTarget}. */
  async fillTarget(
    target: ElementTarget,
    value: string,
    options?: { timeout?: number; strategy?: FillStrategy }
  ): Promise<void> {
    const timeoutMs = actionTimeoutFromSeconds(options?.timeout);
    await this.rpc.call("fill", {
      appHandle: this.appHandle,
      ...target,
      value,
      timeout: timeoutMs / 1_000,
      ...(options?.strategy ? { strategy: options.strategy } : {}),
    }, { timeoutMs: actionRequestTimeoutMs(timeoutMs) });
  }

  /** Return the properties of an element addressed by a query or a handle id.
   *  When `pin` is true and the target is a query, the daemon mints the new handle
   *  with a 60-min idle TTL. Ignored when the target is a pre-existing handle id. */
  async getElementInfo(target: ElementTarget, pin = false): Promise<ElementInfo> {
    return this.rpc.call<ElementInfo>("get_element", {
      appHandle: this.appHandle,
      ...target,
      ...(pin ? { pin: true } : {}),
    });
  }
}

/**
 * MacbethClient manages the daemon and provides app connections.
 */
export class MacbethClient {
  private daemon: DaemonManager;
  private rpc: JsonRpcClient;
  private initialized = false;
  private options: ConnectOptions;

  constructor(options?: ConnectOptions) {
    this.options = options ?? {};
    this.daemon = new DaemonManager({
      socketPath: options?.socketPath,
      binaryPath: options?.daemonPath,
      verbose: options?.verbose,
    });
    this.rpc = new JsonRpcClient({
      timeout: options?.timeout ?? 60_000,
      onReconnect: async () => {
        this.rpc.close();
        this.initialized = false;
        await this.ensureConnected();
      },
    });
  }

  private async ensureConnected(): Promise<void> {
    if (this.initialized && this.rpc.connected) return;

    const socketPath = await this.daemon.ensureRunning();
    await this.rpc.connect(socketPath);
    this.initialized = true;
  }

  /** Health of the daemon connection itself. Failed or timed-out operations do
   *  not degrade it — only an unusable transport does. */
  get health(): HealthSnapshot {
    return this.rpc.health;
  }

  /** List running macOS apps, each annotated with whether it is currently reachable
   *  through the Accessibility API. */
  async listApps(): Promise<AppInfo[]> {
    await this.ensureConnected();
    const result = await this.rpc.call<{ apps: AppInfo[] }>("list_apps");
    return result.apps;
  }

  /** List WindowServer surfaces across every app that owns a window.
   *
   *  Answers "is app X open, and what is it showing?" without connecting to an
   *  app or walking an accessibility tree. Returns real windows only unless
   *  `includeAllSurfaces` is set. */
  async listWindows(options?: ListWindowsOptions): Promise<AppWindowInfo[]> {
    await this.ensureConnected();
    const result = await this.rpc.call<{ windows: AppWindowInfo[] }>(
      "list_windows",
      {
        ...(options?.includeAllSurfaces ? { includeAllSurfaces: true } : {}),
        ...(options?.titlePattern ? { titlePattern: options.titlePattern } : {}),
      }
    );
    return result.windows;
  }

  /** Connect to a running app by name, PID, or an app handle from a previous connect.
   *
   *  Passing a handle (`h_3`) skips name resolution, so a caller that already
   *  disambiguated a fuzzy name keeps addressing the same process.
   *
   *  For Electron apps the daemon enables Chromium's accessibility tree and waits for
   *  it to build before returning. Pass `readyTimeoutMs` to tune that wait (default 3s). */
  async connect(
    target: AppTarget,
    options?: AppConnectOptions
  ): Promise<AppHandle> {
    await this.ensureConnected();

    const params: {
      pid?: number;
      name?: string;
      appHandle?: string;
      readyTimeoutMs?: number;
    } = appConnectParams(target);
    if (options?.readyTimeoutMs !== undefined) {
      params.readyTimeoutMs = options.readyTimeoutMs;
    }

    const result = await this.rpc.call<{
      appHandle: string;
      name: string;
      pid: number;
      bundleId: string | null;
      aliases?: string[];
      runtime?: AppRuntime;
      requestedName?: string | null;
      matchKind?: AppMatchKind;
      matchedValue?: string;
      manualAccessibility?: string;
      webContentReadiness?: TreeDiagnostics["webContent"] | null;
    }>("connect_app", params);

    return new AppHandle(this.rpc, result.appHandle, {
      name: result.name,
      pid: result.pid,
      bundleId: result.bundleId,
      aliases: result.aliases,
      runtime: result.runtime,
      requestedName: result.requestedName,
      matchKind: result.matchKind,
      matchedValue: result.matchedValue,
      manualAccessibility: result.manualAccessibility,
      webContentReadiness: result.webContentReadiness,
    }, { timeout: this.options.timeout });
  }

  /** Run AppleScript or JXA in a deadline-enforced daemon worker process.
   *
   *  `timeoutMs` is clamped to
   *  [{@link SCRIPT_TIMEOUT}.minMs, {@link SCRIPT_TIMEOUT}.maxMs] (default 30s).
   *  Overrunning the deadline rejects with a typed timeout (`JsonRpcError`,
   *  code -32001) for this call only: the daemon connection stays usable and
   *  unrelated calls are unaffected. */
  async runAppleScript(
    source: string,
    language?: "AppleScript" | "JavaScript",
    options?: { interactive?: boolean; timeoutMs?: number },
  ): Promise<string> {
    await this.ensureConnected();
    const timeoutMs = clampScriptTimeoutMs(options?.timeoutMs);
    const result = await this.rpc.call<{ output: string }>("run_applescript", {
      source,
      ...(language ? { language } : {}),
      interactive: options?.interactive ?? true,
      timeoutMs,
    }, { timeoutMs: scriptRequestTimeoutMs(timeoutMs) });
    return result.output;
  }

  /** Begin an explicit interaction-glow activity scope; returns the token that
   *  {@link endActivity} must be called with. Intended for integrations that
   *  control the computer outside Macbeth's own click/fill/key/script tools. */
  async beginActivity(): Promise<string> {
    await this.ensureConnected();
    const result = await this.rpc.call<{ token: string }>("begin_activity", {});
    return result.token;
  }

  /** End an activity scope previously created by {@link beginActivity}. */
  async endActivity(token: string): Promise<void> {
    await this.ensureConnected();
    await this.rpc.call("end_activity", { token });
  }

  /** List every JSON-RPC method the daemon has registered. Used to verify the
   *  MCP tool surface stays in sync with the daemon dispatcher. */
  async listDaemonMethods(): Promise<string[]> {
    await this.ensureConnected();
    const result = await this.rpc.call<{ methods: string[] }>("list_methods", {});
    return result.methods;
  }

  /** Dump all accessibility attributes for a previously resolved element handle. */
  async dumpAttributes(handleId: string): Promise<Record<string, unknown>> {
    await this.ensureConnected();
    return this.rpc.call<Record<string, unknown>>("dump_attributes", { handleId });
  }

  /** Extend a handle's idle TTL to 60 min (refreshed on use). Accepts a single id
   *  (returns `{pinned, handleId}`, throws on failure) or a batch (returns
   *  `{results}` with per-id success/error codes — no batch-wide boolean, since a
   *  mixed batch has no single answer). Pins are finite — there is no unpin. */
  async pinHandle(
    ids: string | string[],
  ): Promise<
    | { pinned: true; handleId: string }
    | { results: Record<string, boolean | { error: string }> }
  > {
    await this.ensureConnected();
    const params = Array.isArray(ids)
      ? { handleIds: ids }
      : { handleId: ids };
    return this.rpc.call("pin_handle", params);
  }

  /** Extract text from an app window or raw image data using OCR */
  async extractText(params: {
    appHandle?: string;
    data?: string;
    windowId?: number;
    region?: { x: number; y: number; width: number; height: number };
  }): Promise<{ items: Array<{ text: string; confidence: number; bbox: { x: number; y: number; w: number; h: number } }> }> {
    await this.ensureConnected();
    return this.rpc.call("extract_text", params);
  }

  /** Shut down the daemon and clean up */
  async close(): Promise<void> {
    this.rpc.close();
    await this.daemon.shutdown();
    this.initialized = false;
  }

  /** Support `await using client = new MacbethClient()` */
  async [Symbol.asyncDispose](): Promise<void> {
    await this.close();
  }
}
