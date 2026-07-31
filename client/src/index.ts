import { MacbethClient, AppHandle } from "./client.js";
import type { ConnectOptions } from "./types.js";

/**
 * Connect to a macOS app by name or PID.
 *
 * @example
 * ```ts
 * import { connect } from 'macbeth';
 *
 * const app = await connect('TextEdit');
 * await app.window('Untitled').textField().fill('Hello');
 * await app.pressKey('s', ['cmd']);
 * await app.pressKeys([{ key: 'return' }, { key: 'tab', delayMs: 100 }]);
 * ```
 */
export async function connect(
  appName: string,
  options?: ConnectOptions
): Promise<AppHandle> {
  const client = new MacbethClient(options);
  return client.connect(appName);
}

export { MacbethClient, AppHandle } from "./client.js";
export { Locator } from "./elements.js";
export { JsonRpcClient, JsonRpcError } from "./rpc.js";
export {
  isConnectionError,
  isOperationTimeout,
  isTransportFailure,
  RPC_ERROR_CODES,
  RPC_ERROR_NAMES,
} from "./errors.js";
export { ServerHealth } from "./health.js";
export type { FailureKind, HealthSnapshot } from "./health.js";
export {
  clampScriptTimeoutMs,
  scriptRequestTimeoutMs,
  scriptTimeoutFromSeconds,
  SCRIPT_TIMEOUT,
} from "./timeouts.js";
export type {
  ConnectOptions,
  AppConnectOptions,
  AppInfo,
  AppWindowInfo,
  ListWindowsOptions,
  AppRuntime,
  AppMatchKind,
  AppAccessibility,
  AXReadiness,
  ClickStrategy,
  ClickOptions,
  FillStrategy,
  TreeOptions,
  ElementInfo,
  ScreenshotResult,
  KeyStroke,
  QueryStep,
  AXNodeJSON,
  TreeDiagnostics,
  QueryTreeDetailedResult,
} from "./types.js";
export { isAppHandle, appConnectParams, formatAppList } from "./app-target.js";
export type { AppTarget } from "./app-target.js";
export { run, runJson } from "./shell.js";
export { runAppleScript } from "./applescript.js";
export { runShortcut, listShortcuts } from "./shortcuts.js";
export { runNativeBridge } from "./native-bridge.js";
