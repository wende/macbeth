export interface QueryStep {
  role?: string;
  title?: string;
  identifier?: string;
  titlePattern?: string;
  index?: number;
}

export type AppRuntime = "native" | "electron" | "unknown";

export interface AppInfo {
  name: string;
  pid: number;
  bundleId: string | null;
  runtime: AppRuntime;
}

export interface ConnectOptions {
  socketPath?: string;
  daemonPath?: string;
  timeout?: number;
  verbose?: boolean;
}

/** Per-connection options. */
export interface AppConnectOptions {
  /** For Electron apps, how long (ms) to wait for Chromium to build its
   *  accessibility tree after enabling it. Default 3000. */
  readyTimeoutMs?: number;
}

/** Strategy for `click`: "auto" tries AXPress (element + neighbours) then a synthetic
 *  mouse click; "ax" only presses; "mouse" only clicks by coordinates. */
export type ClickStrategy = "auto" | "ax" | "mouse";

/** Strategy for `fill`: "auto" does a verified AX write then keyboard synthesis
 *  (always keyboard on Electron); "ax" only writes the AX value; "keyboard" only types. */
export type FillStrategy = "auto" | "ax" | "keyboard";

export interface TreeOptions {
  maxDepth?: number;
  format?: "text" | "json";
  includeInvisible?: boolean;
}

export interface ElementInfo {
  handleId: string;
  role: string;
  title?: string;
  value?: string;
  identifier?: string;
  enabled: boolean;
  focused: boolean;
}

export interface ScreenshotResult {
  data: string;
  width: number;
  height: number;
  format: "png";
}

export type KeyStroke =
  | {
      key: string;
      modifiers?: string[];
      delayMs?: number;
    }
  | {
      text: string;
      delayMs?: number;
    };

export interface FormField {
  handleId: string;
  role: string;
  kind: "text" | "number" | "boolean" | "choice" | "unknown";
  label?: string;
  title?: string;
  value?: string;
  identifier?: string;
  min?: number;
  max?: number;
  editable: boolean;
  enabled: boolean;
}

export interface AXNodeJSON {
  handleId: string;
  role: string;
  title?: string;
  value?: string;
  identifier?: string;
  label?: string;
  enabled: boolean;
  focused: boolean;
  children?: AXNodeJSON[];
}
