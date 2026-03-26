import { DaemonManager } from "./daemon.js";
import { JsonRpcClient } from "./rpc.js";
import { Locator } from "./elements.js";
import type {
  ConnectOptions,
  AppInfo,
  KeyStroke,
  TreeOptions,
  ScreenshotResult,
  QueryStep,
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

  constructor(
    rpc: JsonRpcClient,
    appHandle: string,
    info: { name: string; pid: number; bundleId: string | null },
    options?: { timeout?: number }
  ) {
    super(rpc, appHandle, [], options);
    this.name = info.name;
    this.pid = info.pid;
    this.bundleId = info.bundleId;
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

  /** Capture a screenshot of the app window */
  async screenshot(): Promise<Buffer> {
    const result = await this.rpc.call<ScreenshotResult>("screenshot", {
      appHandle: this.appHandle,
    });
    return Buffer.from(result.data, "base64");
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

  /** Connect to a running app by name or PID */
  async connect(
    nameOrPid: string | number
  ): Promise<AppHandle> {
    await this.ensureConnected();

    const params =
      typeof nameOrPid === "number"
        ? { pid: nameOrPid }
        : { name: nameOrPid };

    const result = await this.rpc.call<{
      appHandle: string;
      name: string;
      pid: number;
      bundleId: string | null;
    }>("connect_app", params);

    return new AppHandle(this.rpc, result.appHandle, {
      name: result.name,
      pid: result.pid,
      bundleId: result.bundleId,
    }, { timeout: this.options.timeout });
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
