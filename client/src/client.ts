import { DaemonManager } from "./daemon.js";
import { JsonRpcClient } from "./rpc.js";
import { Locator } from "./elements.js";
import type { HealthSnapshot } from "./health.js";
import {
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
  }

  /** Opaque app handle used by subsequent RPC calls. */
  get handle(): string {
    return this.appHandle;
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
      maxDepth: options?.maxDepth ?? 5,
      format: options?.format ?? "text",
      includeInvisible: options?.includeInvisible ?? false,
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

  /** List WindowServer surfaces owned by the app or its helper processes. */
  async listWindows(): Promise<AppWindowInfo[]> {
    const result = await this.rpc.call<{ windows: AppWindowInfo[] }>("list_windows", {
      appHandle: this.appHandle,
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
  async readForm(options?: { handleId?: string; query?: QueryStep[]; maxDepth?: number }): Promise<FormField[]> {
    const result = await this.rpc.call<{ fields: FormField[] }>("read_form", {
      appHandle: this.appHandle,
      ...options,
    });
    return result.fields;
  }

  /** List the native menu bar hierarchy through Accessibility. */
  async listMenuBar(): Promise<string> {
    const result = await this.rpc.call<{ menu: string }>("list_menu_bar", {
      appHandle: this.appHandle,
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

  /** Send a keyboard input */
  async pressKey(
    key: string,
    modifiers?: string[]
  ): Promise<void> {
    await this.rpc.call("press_key", {
      appHandle: this.appHandle,
      key,
      modifiers,
    });
  }

  /** Send a sequence of keyboard inputs in one RPC call */
  async pressKeys(keys: KeyStroke[]): Promise<void> {
    await this.rpc.call("press_keys", {
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
    await this.rpc.call("click", {
      appHandle: this.appHandle,
      ...target,
      timeout: options?.timeout ?? 30,
      ...(options?.strategy ? { strategy: options.strategy } : {}),
      ...(options?.waitForIdleMs !== undefined ? { waitForIdleMs: options.waitForIdleMs } : {}),
    });
  }

  /** Fill an element addressed by a locator query or a direct handle id.
   *  `timeout` is in seconds. See {@link clickTarget}. */
  async fillTarget(
    target: ElementTarget,
    value: string,
    options?: { timeout?: number; strategy?: FillStrategy }
  ): Promise<void> {
    await this.rpc.call("fill", {
      appHandle: this.appHandle,
      ...target,
      value,
      timeout: options?.timeout ?? 30,
      ...(options?.strategy ? { strategy: options.strategy } : {}),
    });
  }

  /** Return the properties of an element addressed by a query or a handle id. */
  async getElementInfo(target: ElementTarget): Promise<ElementInfo> {
    return this.rpc.call<ElementInfo>("get_element", {
      appHandle: this.appHandle,
      ...target,
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

  /** List running macOS apps with accessibility support */
  async listApps(): Promise<AppInfo[]> {
    await this.ensureConnected();
    const result = await this.rpc.call<{ apps: AppInfo[] }>("list_apps");
    return result.apps;
  }

  /** Connect to a running app by name or PID.
   *
   *  For Electron apps the daemon enables Chromium's accessibility tree and waits for
   *  it to build before returning. Pass `readyTimeoutMs` to tune that wait (default 3s). */
  async connect(
    nameOrPid: string | number,
    options?: AppConnectOptions
  ): Promise<AppHandle> {
    await this.ensureConnected();

    const params: { pid?: number; name?: string; readyTimeoutMs?: number } =
      typeof nameOrPid === "number"
        ? { pid: nameOrPid }
        : { name: nameOrPid };
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
