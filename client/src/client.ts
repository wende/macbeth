import { DaemonManager } from "./daemon.js";
import { JsonRpcClient } from "./rpc.js";
import { Locator } from "./elements.js";
import type {
  ConnectOptions,
  AppConnectOptions,
  AppInfo,
  AppRuntime,
  KeyStroke,
  TreeOptions,
  ScreenshotResult,
  QueryStep,
  FormField,
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
  readonly runtime: AppRuntime;

  constructor(
    rpc: JsonRpcClient,
    appHandle: string,
    info: { name: string; pid: number; bundleId: string | null; runtime?: AppRuntime },
    options?: { timeout?: number }
  ) {
    super(rpc, appHandle, [], options);
    this.name = info.name;
    this.pid = info.pid;
    this.bundleId = info.bundleId;
    this.runtime = info.runtime ?? "unknown";
  }

  /** Get the AX tree as indented text or JSON */
  async queryTree(options?: TreeOptions): Promise<string> {
    const result = await this.rpc.call<{ tree: string }>("query_tree", {
      appHandle: this.appHandle,
      maxDepth: options?.maxDepth ?? 5,
      format: options?.format ?? "text",
      includeInvisible: options?.includeInvisible ?? false,
    });
    return typeof result.tree === "string"
      ? result.tree
      : JSON.stringify(result.tree, null, 2);
  }

  /** Capture a screenshot of the app window, optionally cropped to a region */
  async screenshot(options?: { region?: { x: number; y: number; width: number; height: number } }): Promise<Buffer> {
    const result = await this.rpc.call<ScreenshotResult>("screenshot", {
      appHandle: this.appHandle,
      ...(options?.region ? { region: options.region } : {}),
    });
    return Buffer.from(result.data, "base64");
  }

  /** Capture a screenshot and return the raw RPC result (base64 + dimensions) */
  async screenshotRaw(options?: { region?: { x: number; y: number; width: number; height: number } }): Promise<ScreenshotResult> {
    return this.rpc.call<ScreenshotResult>("screenshot", {
      appHandle: this.appHandle,
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
      runtime?: AppRuntime;
    }>("connect_app", params);

    return new AppHandle(this.rpc, result.appHandle, {
      name: result.name,
      pid: result.pid,
      bundleId: result.bundleId,
      runtime: result.runtime,
    }, { timeout: this.options.timeout });
  }

  /** Run AppleScript or JXA via the daemon (uses OSAKit, no osascript spawn) */
  async runAppleScript(source: string, language?: "AppleScript" | "JavaScript"): Promise<string> {
    await this.ensureConnected();
    const result = await this.rpc.call<{ output: string }>("run_applescript", {
      source,
      ...(language ? { language } : {}),
    });
    return result.output;
  }

  /** Extract text from an app window or raw image data using OCR */
  async extractText(params: {
    appHandle?: string;
    data?: string;
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
